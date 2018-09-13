/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import RxSwift
import RxCocoa
import FxAClient
import SwiftKeychainWrapper
import WebKit
import Shared

/* These UserDefault keys are maintained separately from the `UserDefaultKey`
 * enum in BaseConstants.swift because, for the time being, they are only
 * useful in the main application. However, rather than maintaining two
 * separate UserDefaults instances, all the values for these keys are stored
 * in the app group instance so that no further migrations will be required
 * in the case that they become relevant in an app extension context. */
enum LocalUserDefaultKey: String {
    case preferredBrowser, recordUsageData, appVersionCode

    static var allValues: [LocalUserDefaultKey] = [.preferredBrowser, .recordUsageData, .appVersionCode]

    var defaultValue: Any? {
        switch self {
        case .preferredBrowser:
            return Constant.setting.defaultPreferredBrowser.rawValue
        case .recordUsageData:
            return Constant.setting.defaultRecordUsageData
        case .appVersionCode:
            return 0
        }
    }
}

class AccountStore: BaseAccountStore {
    static let shared = AccountStore()

    private let dispatcher: Dispatcher
    private let urlCache: URLCache
    private let webData: WKWebsiteDataStore
    private let disposeBag = DisposeBag()

    private var _loginURL = ReplaySubject<URL>.create(bufferSize: 1)
    private var _oldAccountPresence = BehaviorRelay<Bool>(value: false)

    public var loginURL: Observable<URL> {
        return _loginURL.asObservable()
    }

    public var hasOldAccountInformation: Observable<Bool> {
        return _oldAccountPresence.asObservable()
    }

    init(dispatcher: Dispatcher = Dispatcher.shared,
         keychainWrapper: KeychainWrapper = KeychainWrapper.sharedAppContainerKeychain,
         urlCache: URLCache = URLCache.shared,
         webData: WKWebsiteDataStore = WKWebsiteDataStore.default()
        ) {
        self.dispatcher = dispatcher
        self.urlCache = urlCache
        self.webData = webData

        super.init(keychainWrapper: keychainWrapper)
    }

    override func initialized() {
        self.dispatcher.register
                .filterByType(class: AccountAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case .oauthRedirect(let url):
                        self.oauthLogin(url)
                    case .clear:
                        self.clear()
                    case .oauthSignInMessageRead:
                        self.clearOldKeychainValues()
                    }
                })
                .disposed(by: self.disposeBag)

        self.dispatcher.register
                .filterByType(class: LifecycleAction.self)
                .subscribe(onNext: { [weak self] action in
                    guard case let .upgrade(previous, _) = action,
                        let self = self else {
                        return
                    }

                    if previous <= 1 {
                        self._oauthInfo.onNext(nil)
                        self._profile.onNext(nil)
                        self._oldAccountPresence.accept(true)
                    }
                })
                .disposed(by: self.disposeBag)

        if let accountJSON = self.storedAccountJSON {
            self.fxa = try? FirefoxAccount.fromJSON(state: accountJSON)
            self.generateLoginURL()
            self.populateAccountInformation()
        } else {
            FxAConfig.release { (config: FxAConfig?, _) in
                if let config = config {
                   self.fxa = try? FirefoxAccount(
                           config: config,
                           clientId: Constant.fxa.clientID,
                           redirectUri: Constant.fxa.redirectURI)

                    self.generateLoginURL()
                }

                self._oauthInfo.onNext(nil)
                self._profile.onNext(nil)
            }
        }
    }
}

extension AccountStore {
    private func generateLoginURL() {
        self.fxa?.beginOAuthFlow(scopes: Constant.fxa.scopes, wantsKeys: true) { url, _ in
            if let url = url {
                self._loginURL.onNext(url)
            }
        }
    }

    private func clear() {
        for identifier in KeychainKey.allValues {
            _ = self.keychainWrapper.removeObject(forKey: identifier.rawValue)
        }

        self.webData.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            self.webData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { }
        }

        self.urlCache.removeAllCachedResponses()

        self._profile.onNext(nil)
        self._oauthInfo.onNext(nil)
    }

    private func clearOldKeychainValues() {
        for identifier in KeychainKey.oldAccountValues {
            _ = KeychainWrapper.standard.removeObject(forKey: identifier.rawValue)
        }

        self.webData.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            self.webData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { }
        }

        self._oldAccountPresence.accept(false)
    }

    private func oauthLogin(_ navigationURL: URL) {
        guard let components = URLComponents(url: navigationURL, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            return
        }

        var dic = [String: String]()
        queryItems.forEach {
            dic[$0.name] = $0.value
        }

        guard let code = dic["code"],
              let state = dic["state"] else {
            return
        }

        self.fxa?.completeOAuthFlow(code: code, state: state) { (info: OAuthInfo?, _) in
            self._oauthInfo.onNext(info)

            guard let fxa = self.fxa else {
                return
            }

            if let accountJSON = try? fxa.toJSON() {
                self.keychainWrapper.set(accountJSON, forKey: KeychainKey.accountJSON.rawValue)
            }

            fxa.getProfile { (profile: Profile?, _) in
                self._profile.onNext(profile)
            }
        }
    }
}

//
//  SignupViewModelImpl.swift
//  ProtonMail - Created on 3/29/16.
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.


import Foundation
import Crypto


final class SignupViewModelImpl : SignupViewModel {
    fileprivate var userName : String = ""
    fileprivate var token : String = ""
    fileprivate var isExpired : Bool = true
    fileprivate var newPrivateKey : String?
    fileprivate var domain : String = ""
    fileprivate var destination : String = ""
    fileprivate var recoverEmail : String = ""
    fileprivate var news : Bool = true
    fileprivate var plaintext_password : String = ""
    fileprivate var agreePolicy : Bool = false
    fileprivate var displayName : String = ""
    
    fileprivate var lastSendTime : Date?
    
    fileprivate var keysalt : Data?
    fileprivate var keypwd_with_keysalt : String = ""
    fileprivate var bit : Int = 2048
    
    fileprivate var delegate : SignupViewModelDelegate?
    fileprivate var verifyType : VerifyCodeType = .email
    
    fileprivate var direct : [String] = []
    
    let deviceCheckToken: String
    
    override func getDirect() -> [String] {
        return direct
    }
    
    init(token: String) {
        self.deviceCheckToken = token
        
        super.init()
        //register observer
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(SignupViewModelImpl.notifyReceiveURLSchema(_:)),
                                               name: .customUrlSchema,
                                               object:nil)
    }
    deinit {
        //unregister observer
        NotificationCenter.default.removeObserver(self, name: .customUrlSchema, object:nil)
    }
    
    @objc internal func notifyReceiveURLSchema (_ notify: Notification) {
        if let verifyCode = notify.userInfo?["verifyCode"] as? String {
            delegate?.verificationCodeChanged(self, code: verifyCode)
        }
    }
    
    override func setDelegate(_ delegate: SignupViewModelDelegate?) {
        self.delegate = delegate
    }
    
    override func checkUserName(_ username: String, complete: CheckUserNameBlock!) {
        // need valide user name format
        let api = CheckUserExist(userName: username)
        api.call { (task, response, hasError) -> Void in
            if let error = response?.error {
                complete(.rejected(error))
            } else if let status = response?.availabilityStatus {
                complete(.fulfilled(status))
            } else {
                complete(.rejected(NSError.init(domain: "", code: 0, localizedDescription: "Failed to determine status")))
            }
        }
    }
    
    override func getCurrentBit() -> Int {
        return self.bit
    }
    
    override func setBit(_ bit: Int) {
        self.bit = bit
    }
    
    override func setRecaptchaToken(_ token: String, isExpired: Bool) {
        self.token = token
        self.isExpired = isExpired
        self.verifyType = .recaptcha
    }
    
    override func setPickedUserName(_ username: String, domain:String) {
        self.userName = username
        self.domain = domain
    }
    
    override func isTokenOk() -> Bool {
        return !isExpired
    }
    
    override func setEmailVerifyCode(_ code: String) {
        self.token = code
        self.isExpired = false
        self.verifyType = .email
    }
    
    override func setPhoneVerifyCode (_ code: String) {
        self.token = code
        self.isExpired = false
        self.verifyType = .sms
    }
    
    override func generateKey(_ complete: @escaping GenerateKey) {
        {
            do {
                //generate key salt
                let new_mpwd_salt : Data = PMNOpenPgp.randomBits(128) //mailbox pwd need 128 bits
                //generate key hashed password.
                let new_hashed_mpwd = PasswordUtils.getMailboxPassword(self.plaintext_password, salt: new_mpwd_salt)
                self.keysalt = new_mpwd_salt
                self.keypwd_with_keysalt = new_hashed_mpwd
                //generate new key
                
//                self.newPrivateKey = try sharedOpenPGP.generateKey(self.userName,
//                                                                   domain: self.domain,
//                                                                   passphrase: new_hashed_mpwd,
//                                                                   keyType: "rsa", bits: self.bit);
                let pgp = PMNOpenPgp.createInstance()!
                let newK = try pgp.generateKey(new_hashed_mpwd,
                                               userName: self.userName,
                                               domain: self.domain,
                                               bits: Int32(self.bit))
                self.newPrivateKey = newK?.privateKey;
                
                {
                    // do some async stuff
                    if self.newPrivateKey == nil {
                        complete(true, LocalString._key_generation_failed_please_try_again, nil)
                    } else {
                        complete(false, nil, nil);
                    }
                } ~> .main
            }
            catch let ex as NSError {
                { complete(false, LocalString._key_generation_failed_please_try_again, ex) } ~> .main
            }
        } ~> .async
    }
    
    override func createNewUser(_ complete: @escaping CreateUserBlock) {
        //validation here
        if let key = self.newPrivateKey {
            {
                do {
                    let authModuls = try AuthModulusRequest(authCredential: nil).syncCall()
                    guard let moduls_id = authModuls?.ModulusID else {
                        throw SignUpCreateUserError.invalidModulsID.error
                    }
                    guard let new_moduls = authModuls?.Modulus else {
                        throw SignUpCreateUserError.invalidModuls.error
                    }
                    //generat new verifier
                    let new_salt : Data = PMNOpenPgp.randomBits(80) //for the login password needs to set 80 bits
                    
                    guard let auth = try SrpAuthForVerifier(self.plaintext_password, new_moduls, new_salt) else {
                        throw SignUpCreateUserError.cantHashPassword.error
                    }
                    let verifier = try auth.generateVerifier(2048)
                    
                    let api = CreateNewUser(token: self.token,
                                            type: self.verifyType.toString, username: self.userName,
                                            email: self.recoverEmail,
                                            modulusID: moduls_id,
                                            salt: new_salt.encodeBase64(),
                                            verifer: verifier.encodeBase64(), deviceToken: self.deviceCheckToken)
                    api.call({ (task, response, hasError) -> Void in
                        if !hasError {
                            //need clean the cache without ui flow change then signin with a fresh user
                            sharedUserDataService.signOutAfterSignUp()
                            userCachedStatus.signOut()
                            sharedMessageDataService.launchCleanUpIfNeeded()
                            
                            //login first
                            sharedUserDataService.signIn(self.userName, password: self.plaintext_password,
                                                         twoFACode: nil, checkSalt: false,
                                ask2fa: {
                                    //2fa will show error
                                    complete(false, true, LocalString._signup_2fa_auth_failed, nil)
                                },
                                onError: { (error) in
                                    complete(false, true, LocalString._authentication_failed_pls_try_again, error);
                                },
                                onSuccess: { (mailboxpwd) in
                                    {
                                        do {
                                            try AuthCredential.setupToken(self.keypwd_with_keysalt, isRememberMailbox: true)
                                            
                                            //need setup address
                                            let setupAddrApi = try SetupAddressRequest(domain_name: self.domain).syncCall()
                                            
                                            //need setup keys
                                            let authModuls_for_key = try AuthModulusRequest(authCredential: nil).syncCall()
                                            guard let moduls_id_for_key = authModuls_for_key?.ModulusID else {
                                                throw SignUpCreateUserError.invalidModulsID.error
                                            }
                                            guard let new_moduls_for_key = authModuls_for_key?.Modulus else {
                                                throw SignUpCreateUserError.invalidModuls.error
                                            }
                                            //generat new verifier
                                            let new_salt_for_key : Data = PMNOpenPgp.randomBits(80) //for the login password needs to set 80 bits
                                            guard let auth_for_key = try SrpAuthForVerifier(self.plaintext_password, new_moduls_for_key,
                                                                                           new_salt_for_key) else {
                                                throw SignUpCreateUserError.cantHashPassword.error
                                            }
                                            let verifier_for_key = try auth_for_key.generateVerifier(2048)
                                            
                                            let addr_id = setupAddrApi?.addresses.first?.address_id
                                            let pwd_auth = PasswordAuth(modulus_id: moduls_id_for_key,
                                                                        salt: new_salt_for_key.encodeBase64(),
                                                                        verifer: verifier_for_key.encodeBase64())
                                            
                                            
                                            guard !key.fingerprint.isEmpty else {
                                                //TODO:: change to a key error
                                                throw SignUpCreateUserError.cantHashPassword.error
                                            }
                                            let keylist : [[String: Any]] = [[
                                                "Fingerprint" :  key.fingerprint,
                                                "Primary" : 1,
                                                "Flags" : 3
                                            ]]
                                            
                                            let jsonKeylist = keylist.json()
                                            let signed = try! Crypto().signDetached(plainData: jsonKeylist,
                                                                                    privateKey: key,
                                                                                    passphrase: self.keypwd_with_keysalt)
                                            let signedKeyList : [String: Any] = [
                                                "Data" : jsonKeylist,
                                                "Signature" : signed
                                            ]
                                            
                                            let setupKeyApi = try SetupKeyRequest(address_id: addr_id!,
                                                                                  private_key: key,
                                                                                  keysalt: self.keysalt!.encodeBase64(),
                                                                                  signedKL: signedKeyList,
                                                                                  auth: pwd_auth).syncCall()
                                            if setupKeyApi?.error != nil {
                                                PMLog.D("signup seupt key error")
                                            }
                                            
                                            //setup swipe function, will use default auth credential
                                            let _ = try UpdateSwiftLeftAction(action: MessageSwipeAction.archive, authCredential: nil).syncCall()
                                            let _ = try UpdateSwiftRightAction(action: MessageSwipeAction.trash, authCredential: nil).syncCall()

                                            sharedLabelsDataService.fetchLabels()
                                            ServicePlanDataService.shared.updateCurrentSubscription()
                                            sharedUserDataService.fetchUserInfo().done(on: .main) { info in
                                                if info != nil {
                                                    sharedUserDataService.isNewUser = true
                                                    sharedUserDataService.setMailboxPassword(self.keypwd_with_keysalt, keysalt: nil)
                                                    //alway signle password mode when signup
                                                    sharedUserDataService.passwordMode = 1
                                                    complete(true, true, "", nil)
                                                } else {
                                                    complete(false, true, LocalString._unknown_error, nil)
                                                }
                                            }.catch(on: .main) { error in
                                                complete(false, true, LocalString._fetch_user_info_failed, error)
                                            }
                                        } catch let ex as NSError {
                                            PMLog.D(any: ex)
                                            complete(false, true, ex.localizedDescription, nil);
                                        }
                                    } ~> .async
                            })
                        } else {
                            if response?.error?.code == 7002 {
                                complete(false, true, LocalString._account_creation_has_been_disabled_pls_go_to_https, response!.error);
                            } else {
                                complete(false, false, LocalString._create_user_failed_please_try_again, response!.error);
                            }
                        }
                    })
                } catch {
                    complete(false, false, LocalString._create_user_failed_please_try_again, nil);
                }
                
            } ~> .async
            
        } else {
            complete(false, false, LocalString._key_invalid_please_go_back_try_again, nil);
        }
    }
    
    override func sendVerifyCode(_ type: VerifyCodeType, complete: SendVerificationCodeBlock!) {
        let api = VerificationCodeRequest(userName: self.userName, destination: destination, type: type)
        api.call { (task, response, hasError) -> Void in
            if !hasError {
                self.lastSendTime = Date()
            }
            complete(!hasError, response?.error)
        }
    }
    
    override func setRecovery(_ receiveNews: Bool, email: String, displayName : String) {
        self.recoverEmail = email
        self.news = receiveNews
        self.displayName = displayName
        
        if !self.displayName.isEmpty {
            if let addr = sharedUserDataService.addresses.defaultAddress() {
                sharedUserDataService.updateAddress(addr.address_id, displayName: displayName, signature: addr.signature, completion: { (_, _, error) in
                    
                })
            } else {
                sharedUserDataService.updateDisplayName(displayName) { _, _, error in
                    
                }
            }
        }
        
        if !self.recoverEmail.isEmpty {
            sharedUserDataService.updateNotificationEmail(recoverEmail, login_password: self.plaintext_password, twoFACode: nil) { _, _, error in

            }
        }
        
        let newsApi = UpdateNewsRequest(news: self.news)
        newsApi.call { (task, response, hasError) -> Void in
            
        }
    }
    
    override func fetchDirect(_ res : @escaping (_ directs:[String]) -> Void) {
        if direct.count <= 0 {
            let api = DirectRequest()
            api.call { (task, response, hasError) -> Void in
                if hasError {
                    res([])
                } else {
                    self.direct = response?.signupFunctions ?? []
                    res(self.direct)
                }
            }
        } else {
            res(self.direct)
        }
    }
    
    override func setCodeEmail(_ email: String) {
        self.destination = email
        //self.recoverEmail = email
        self.news = true
    }
    
    override func setCodePhone(_ phone: String) {
        self.destination = phone
    }
    
    override func setSinglePassword(_ password: String) {
        self.plaintext_password = password
    }
    
    override func setAgreePolicy(_ isAgree: Bool) {
        self.agreePolicy = isAgree;
    }
    
    fileprivate var count : Int = 10;
    override func getTimerSet() -> Int {
        if let lastTime = lastSendTime {
            let time = Date().timeIntervalSince(lastTime)
            let newCount = 120 - Int(time);
            if newCount <= 0 {
                lastSendTime = nil
            }
            return newCount > 0 ? newCount : 0;
        } else {
            return 0
        }
    }
    
    override func getDomains(_ complete : @escaping AvailableDomainsComplete) -> Void {
        let defaultDomains = ["protonmail.com", "protonmail.ch"]
        let api = GetAvailableDomainsRequest()
        api.call({ (task, response, hasError) -> Void in
            if hasError {
                complete(defaultDomains)
            } else if let domains = response?.domains {
                complete(domains)
            } else {
                complete(defaultDomains)
            }
        })
    }
}

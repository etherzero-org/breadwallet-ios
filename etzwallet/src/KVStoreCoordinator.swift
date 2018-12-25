//
//  KVStoreCoordinator.swift
//  breadwallet
//
//  Created by Adrian Corscadden on 2017-03-12.
//  Copyright © 2017 breadwallet LLC. All rights reserved.
//

import Foundation

class KVStoreCoordinator : Subscriber {

    init(kvStore: BRReplicatedKVStore) {
        self.kvStore = kvStore
        setupStoredCurrencyList()
    }
    
    private func save(metaData:CurrencyListMetaData) {
        do {
            let _ = try kvStore.set(metaData)
        } catch let error {
            print("error setting wallet info: \(error)")
        }
    }

    func setupStoredCurrencyList() {
        //If stored currency list metadata doesn't exist, create a new one
        guard CurrencyListMetaData(kvStore: kvStore) != nil else {
            let newCurrencyListMetaData = CurrencyListMetaData()
            newCurrencyListMetaData.enabledCurrencies = CurrencyListMetaData.defaultCurrencies
            set(newCurrencyListMetaData)
            // 这个数据是通过异步获取的，这里直接拿不到 tokenData 数据，所以这里数据初始化会有问题，这行代码暂时需要注释掉
//            setInitialDisplayWallets(metaData: newCurrencyListMetaData, tokenData: [])
            setWallets()
            return
        }
        setWallets()
    }
    
    private func setWallets() {
        guard let currencyMetaData = CurrencyListMetaData(kvStore: kvStore) else {
            return setupStoredCurrencyList()
        }
        
        if currencyMetaData.doesRequireSave == 1 {
            currencyMetaData.doesRequireSave = 0
            set(currencyMetaData)
            try? kvStore.syncKey(tokenListMetaDataKey, completionHandler: {_ in })
        }
        
        if !currencyMetaData.enabledCurrencies.contains("0x013b6e279989aa20819a623630fe678c9f43a48f") {
            let newCurrencyListMetaData = CurrencyListMetaData(kvStore: self.kvStore)!
            newCurrencyListMetaData.enabledCurrencies = CurrencyListMetaData.defaultCurrencies
            currencyMetaData.enabledCurrencies = CurrencyListMetaData.defaultCurrencies
            save(metaData: newCurrencyListMetaData)
        }
        
//        if !UserDefaults.standard.bool(forKey: "isAddEash") {
//            currencyMetaData.addTokenAddresses(addresses: [Currencies.eash.address])
//            UserDefaults.standard.set(true, forKey: "isAddEash")
//        }
        
        StoredTokenData.fetchTokens(callback: { tokenData in
            self.setInitialDisplayWallets(metaData: currencyMetaData, tokenData: tokenData.map { ERC20Token(tokenData: $0) })
        })
        
        Store.subscribe(self, name: .resetDisplayCurrencies, callback: { _ in
            self.resetDisplayCurrencies()
        })
    }

    private func resetDisplayCurrencies() {
        guard let currencyMetaData = CurrencyListMetaData(kvStore: kvStore) else {
            return setupStoredCurrencyList()
        }
        currencyMetaData.enabledCurrencies = CurrencyListMetaData.defaultCurrencies
        currencyMetaData.hiddenCurrencies = []
        set(currencyMetaData)
        try? kvStore.syncKey(tokenListMetaDataKey, completionHandler: {_ in })
        setInitialDisplayWallets(metaData: currencyMetaData, tokenData: [])
    }

    private func setInitialDisplayWallets(metaData: CurrencyListMetaData, tokenData: [ERC20Token]) {
        //skip this setup if stored wallets are the same as wallets in the state
        guard walletsHaveChanged(displayCurrencies: Store.state.displayCurrencies, enabledCurrencies: metaData.enabledCurrencies) else { return }

        let oldWallets = Store.state.wallets
        var newWallets = [String: WalletState]()
        var displayOrder = 0

        metaData.enabledCurrencies.forEach {
            if let walletState = oldWallets[$0] {
                newWallets[$0] = walletState.mutate(displayOrder: displayOrder)
                displayOrder = displayOrder + 1
            } else {
                //Since a WalletState wasn't found, it must be a token address
                let tokenAddress = $0.replacingOccurrences(of: C.erc20Prefix, with: "")
                
                let filteredTokens = tokenData.filter { $0.address.lowercased() == tokenAddress.lowercased() }
                if let token = filteredTokens.first {
                    if let oldWallet = oldWallets[token.code] {
                        newWallets[token.code] = oldWallet.mutate(displayOrder: displayOrder)
                    } else {
                        newWallets[token.code] = WalletState.initial(token, displayOrder: displayOrder)
                    }
                    displayOrder = displayOrder + 1
                } else {
                    assert(E.isTestnet, "unknown token")
                }
                
                if tokenAddress.lowercased() == Currencies.eash.address.lowercased() {
                    newWallets[Currencies.eash.code] = oldWallets[Currencies.eash.code]!.mutate(displayOrder: displayOrder)
                    displayOrder = displayOrder + 1
                } else {
                    let filteredTokens = tokenData.filter { $0.address.lowercased() == tokenAddress.lowercased() }
                    if let token = filteredTokens.first {
                        if let oldWallet = oldWallets[token.code] {
                            newWallets[token.code] = oldWallet.mutate(displayOrder: displayOrder)
                        } else {
                            newWallets[token.code] = WalletState.initial(token, displayOrder: displayOrder)
                        }
                        displayOrder = displayOrder + 1
                    } else {
                        assert(E.isTestnet, "unknown token")
                    }
                }
            }
        }

        //Re-add hidden default currencies
        CurrencyListMetaData.defaultCurrencies.forEach {
            if let walletState = oldWallets[$0] {
                if newWallets[$0] == nil {
                    newWallets[$0] = walletState
                }
            }
            let tokenAddress = $0.replacingOccurrences(of: C.erc20Prefix, with: "")
            if tokenAddress.lowercased() == Currencies.eash.address.lowercased() {
                if newWallets[Currencies.eash.code] == nil {
                    newWallets[Currencies.eash.code] = oldWallets[Currencies.eash.code]
                }
            }
        }
        Store.perform(action: ManageWallets.setWallets(newWallets))
    }

    private func walletsHaveChanged(displayCurrencies: [CurrencyDef], enabledCurrencies: [String]) -> Bool {
        let identifiers: [String] = displayCurrencies.map {
            if let token = $0 as? ERC20Token {
                return C.erc20Prefix + token.address
            } else {
                return $0.code
            }
        }
        return identifiers != enabledCurrencies
    }
    
    func retreiveStoredWalletInfo() {
        guard !hasRetreivedInitialWalletInfo else { return }
        if let walletInfo = WalletInfo(kvStore: kvStore) {
            //TODO:BCH
            Store.perform(action: WalletChange(Currencies.btc).setWalletName(walletInfo.name))
            Store.perform(action: WalletChange(Currencies.btc).setWalletCreationDate(walletInfo.creationDate))
        } else {
            print("no wallet info found")
        }
        hasRetreivedInitialWalletInfo = true
    }

    func listenForWalletChanges() {
        Store.subscribe(self,
                        selector: { $0[Currencies.btc]?.creationDate != $1[Currencies.btc]?.creationDate },
                            callback: {
                                if let existingInfo = WalletInfo(kvStore: self.kvStore) {
                                    Store.perform(action: WalletChange(Currencies.btc).setWalletCreationDate(existingInfo.creationDate))
                                } else {
                                    guard let btcState = $0[Currencies.btc] else { return }
                                    let newInfo = WalletInfo(name: btcState.name)
                                    newInfo.creationDate = btcState.creationDate
                                    self.set(newInfo)
                                }
        })
    }

    private func set(_ info: BRKVStoreObject) {
        do {
            let _ = try kvStore.set(info)
        } catch let error {
            print("error setting wallet info: \(error)")
        }
    }

    private let kvStore: BRReplicatedKVStore
    private var hasRetreivedInitialWalletInfo = false
}

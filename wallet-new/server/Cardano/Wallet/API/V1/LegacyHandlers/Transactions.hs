{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Wallet.API.V1.LegacyHandlers.Transactions where

import           Universum

import           Cardano.Wallet.API.Request
import           Cardano.Wallet.API.Response
import           Cardano.Wallet.API.V1.Migration (HasCompileInfo, HasConfigurations, MonadV1,
                                                  migrate)
import qualified Cardano.Wallet.API.V1.Transactions as Transactions
import           Cardano.Wallet.API.V1.Types
import qualified Data.IxSet.Typed as IxSet
import           Data.Default
import qualified Data.List.NonEmpty as NE
import           Servant
import qualified Pos.Client.Txp.Util as V0
import           Pos.Core (TxAux, decodeTextAddress)
import           Pos.Util (eitherToThrow)
import qualified Pos.Wallet.Web.ClientTypes.Types as V0
import qualified Pos.Wallet.Web.Methods.History as V0
import qualified Pos.Wallet.Web.Methods.Payment as V0
import qualified Pos.Wallet.Web.Methods.Txp as V0
import qualified Pos.Wallet.Web.Util as V0

handlers :: ( HasConfigurations
            , HasCompileInfo
            )
         => (TxAux -> MonadV1 Bool) -> ServerT Transactions.API MonadV1

handlers submitTx =
             newTransaction submitTx
        :<|> allTransactions
        :<|> estimateFees

newTransaction
    :: forall ctx m . (V0.MonadWalletTxFull ctx m)
    => (TxAux -> m Bool) -> Payment -> m (WalletResponse Transaction)
newTransaction submitTx Payment {..} = do
    let spendingPw = fromMaybe mempty pmtSpendingPassword
    cAccountId <- migrate (pmtSourceWallet, pmtSourceAccount)
    addrCoinList <- migrate $ NE.toList pmtDestinations
    policy <- migrate $ fromMaybe def pmtGroupingPolicy
    let batchPayment = V0.NewBatchPayment cAccountId addrCoinList policy
    cTx <- V0.newPaymentBatch submitTx spendingPw batchPayment
    single <$> migrate cTx


allTransactions
    :: forall ctx m. (V0.MonadWalletHistory ctx m)
    => WalletId
    -> Maybe AccountId
    -> Maybe Text
    -> RequestParams
    -> m (WalletResponse [Transaction])
allTransactions walletId mAccId mTextAddr requestParams = do
    cIdWallet <- migrate walletId

    -- Create a `[V0.AccountId]` to get txs from it
    accIds <- case mAccId of
        Just accId -> pure $ migrate (walletId, accId)
        -- ^ Migrate `V1.AccountId` into `V0.AccountId` and put it into a list
        Nothing -> V0.getWalletAccountIds cIdWallet
        -- ^ Or get all `V0.AccountId`s of a wallet

    -- Helper to create a `V1.Address` from a `Text` address
    -- and migrate it into `(V0.CId V0.Addr)`
    let mV0AddrFromTextAddr addr =
            either (const Nothing) (Just . migrate) (decodeTextAddress addr)

    -- Try to get `(V0.CId V0.Addr)` from a `Text` address
    let mV0Addr = case mTextAddr of
            Nothing -> Nothing
            Just textAddr -> fromMaybe Nothing (mV0AddrFromTextAddr textAddr)

    -- get all `[Transaction]`'s
    let transactions = do
            (V0.WalletHistory wh, _) <- V0.getHistory cIdWallet accIds mV0Addr
            migrate wh

    -- Paginate result
    respondWith requestParams (NoFilters :: FilterOperations Transaction)
                              (NoSorts :: SortOperations Transaction)
                              (IxSet.fromList <$> transactions)


estimateFees :: (MonadThrow m, V0.MonadFees ctx m)
    => Payment
    -> m (WalletResponse EstimatedFees)
estimateFees Payment{..} = do
    policy <- migrate $ fromMaybe def pmtGroupingPolicy
    pendingAddrs <- V0.getPendingAddresses policy
    cAccountId <- migrate (pmtSourceWallet, pmtSourceAccount)
    utxo <- V0.getMoneySourceUtxo (V0.AccountMoneySource cAccountId)
    outputs <- V0.coinDistrToOutputs =<< mapM migrate pmtDestinations
    fee <- V0.rewrapTxError "Cannot compute transaction fee" $
        eitherToThrow =<< V0.runTxCreator policy (V0.computeTxFee pendingAddrs utxo outputs)
    single <$> migrate fee

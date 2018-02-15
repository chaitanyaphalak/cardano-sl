{-# LANGUAGE Rank2Types   #-}
{-# LANGUAGE TypeFamilies #-}

-- @jens: this document is inspired by https://github.com/input-output-hk/rscoin-haskell/blob/master/src/RSCoin/Explorer/Storage.hs
module Pos.Wallet.Web.State.Storage
       (
         WalletStorage (..)
       , HasWalletStorage (..)
       , WAddressMeta (..)
       , HasWAddressMeta (..)
       , wamAccount
       , WalletInfo (..)
       , AccountInfo (..)
       , AddressInfo (..)
       , AddressLookupMode (..)
       , CAddresses
       , CustomAddressType (..)
       , CurrentAndRemoved (..)
       , WalletBalances
       , WalBalancesAndUtxo
       , WalletTip (..)
       , PtxMetaUpdate (..)
       , Query
       , Update
       , getWalletStorage
       , flushWalletStorage
       , getProfile
       , setProfile
       , doesAccountExist
       , getAccountIds
       , getAccountMetas
       , getAccountMeta
       , getAccountAddrMaps
       , getWalletMetas
       , getWalletMeta
       , getWalletMetaIncludeUnready
       , getWalletPassLU
       , getWalletSyncTip
       , getWalletAddresses
       , getAccountWAddresses
       , getWAddresses
       , doesWAddressExist
       , getTxMeta
       , getUpdates
       , getNextUpdate
       , getHistoryCache
       , getCustomAddresses
       , getCustomAddress
       , getPendingTxs
       , getWalletPendingTxs
       , getPendingTx
       , addCustomAddress
       , removeCustomAddress
       , createAccount
       , createWallet
       , addWAddress
       , addRemovedAccount
       , setAccountMeta
       , setWalletMeta
       , setWalletReady
       , setWalletPassLU
       , setWalletSyncTip
       , setWalletTxHistory
       , getWalletTxHistory
       , getWalletUtxo
       , getWalletBalancesAndUtxo
       , updateWalletBalancesAndUtxo
       , setWalletUtxo
       , addOnlyNewTxMeta
       , setWalletTxMeta
       , addOnlyNewTxMetas
       , removeWallet
       , removeWalletTxMetas
       , removeTxMetas
       , removeHistoryCache
       , removeAccount
       , removeWAddress
       , totallyRemoveWAddress
       , addUpdate
       , removeNextUpdate
       , testReset
       , updateHistoryCache
       , insertIntoHistoryCache
       , removeFromHistoryCache
       , setPtxCondition
       , casPtxCondition
       , ptxUpdateMeta
       , addOnlyNewPendingTx
       , cancelApplyingPtxs
       , cancelSpecificApplyingPtx
         -- * Exported only for testing purposes
       , AddressInfo_v0 (..)
       , AccountInfo_v0 (..)
       , WalletStorage_v2(..)
       ) where

import           Universum

import           Control.Arrow                   ((***))
import           Control.Lens                    (at, ix, lens, makeClassy, makeLenses,
                                                  non', to, toListOf, traversed, (%=),
                                                  (+=), (.=), (<<.=), (?=), _Empty, _head)
import           Control.Monad.State.Class       (put)
import           Data.Default                    (Default, def)
import           Data.Hashable                   (Hashable)
import qualified Data.HashMap.Strict             as HM
import qualified Data.Map                        as M
import           Data.SafeCopy                   (Migrate (..), base,
                                                  deriveSafeCopySimple, extension)
import           Data.Time.Clock.POSIX           (POSIXTime)

import qualified Data.Text.Buildable
import           Formatting                      ((%))
import qualified Formatting                      as F
import           Pos.Client.Txp.History          (TxHistoryEntry, txHistoryListToMap)
import           Pos.Core.Configuration.Protocol (HasProtocolConstants)
import           Pos.Core.Types                  (Address, SlotId, Timestamp)
import           Pos.Txp                         (AddrCoinMap, TxAux, TxId, Utxo,
                                                  UtxoModifier, applyUtxoModToAddrCoinMap,
                                                  utxoToAddressCoinMap)
import           Pos.Types                       (HeaderHash)
import           Pos.Util.BackupPhrase           (BackupPhrase)
import qualified Pos.Util.Modifier               as MM
import qualified Pos.Wallet.Web.ClientTypes      as WebTypes
import           Pos.Wallet.Web.Pending.Types    (PendingTx (..), PtxCondition,
                                                  PtxSubmitTiming (..), ptxCond,
                                                  ptxSubmitTiming)
import           Pos.Wallet.Web.Pending.Updates  (cancelApplyingPtx,
                                                  incPtxSubmitTimingPure,
                                                  mkPtxSubmitTiming,
                                                  ptxMarkAcknowledgedPure)

-- | Address with associated metadata locating it in an account in a wallet.
data WAddressMeta = WAddressMeta
    { _wamWalletId     :: WebTypes.CId WebTypes.Wal
    , _wamAccountIndex :: Word32
    , _wamAddressIndex :: Word32
    , _wamAddress      :: Address
    } deriving (Eq, Ord, Show, Generic, Typeable)

makeClassy ''WAddressMeta
instance Hashable WAddressMeta
instance Buildable WAddressMeta where
    build WAddressMeta{..} =
        F.bprint (F.build%"@"%F.build%"@"%F.build%" ("%F.build%")")
        _wamWalletId _wamAccountIndex _wamAddressIndex _wamAddress

-- | Lens to extract the account from an 'AddressMeta'
wamAccount :: Lens' WAddressMeta WebTypes.AccountId
wamAccount = lens
    (WebTypes.AccountId <$> view wamWalletId <*> view wamAccountIndex)
    (\am (WebTypes.AccountId wid accIdx) -> set wamWalletId wid
                                            . set wamAccountIndex accIdx $ am)

type AddressSortingKey = Int

data AddressInfo = AddressInfo
    { adiWAddressMeta :: !WAddressMeta
    , adiSortingKey   :: !AddressSortingKey
    }

type CAddresses = HashMap Address AddressInfo

data AccountInfo = AccountInfo
    { _aiMeta             :: !WebTypes.CAccountMeta
    , _aiAddresses        :: !CAddresses
    , _aiRemovedAddresses :: !CAddresses
    , _aiUnusedKey        :: !AddressSortingKey
    }

makeLenses ''AccountInfo

data WalletTip
    = NotSynced
    | SyncedWith !HeaderHash

data WalletInfo = WalletInfo
    { _wiMeta         :: !WebTypes.CWalletMeta
    , _wiPassphraseLU :: !WebTypes.PassPhraseLU
    , _wiCreationTime :: !POSIXTime
    , _wiSyncTip      :: !WalletTip
    , _wsPendingTxs   :: !(HashMap TxId PendingTx)
    -- Wallets that are being synced are marked as not ready, and
    -- are excluded from api endpoints. This info should not be leaked
    -- into a client facing data structure (for example `CWalletMeta`)
    , _wiIsReady      :: !Bool
    }

makeLenses ''WalletInfo

-- | Maps addresses to their first occurrence in the blockchain
type CustomAddresses = HashMap Address HeaderHash
type WalletBalances = AddrCoinMap
type WalBalancesAndUtxo = (WalletBalances, Utxo)

data WalletStorage = WalletStorage
    { _wsWalletInfos     :: !(HashMap (WebTypes.CId WebTypes.Wal) WalletInfo)
    , _wsAccountInfos    :: !(HashMap WebTypes.AccountId AccountInfo)
    , _wsProfile         :: !WebTypes.CProfile
    , _wsReadyUpdates    :: [WebTypes.CUpdateInfo]
    , _wsTxHistory       :: !(HashMap (WebTypes.CId WebTypes.Wal) (HashMap WebTypes.CTxId WebTypes.CTxMeta))
    , _wsHistoryCache    :: !(HashMap (WebTypes.CId WebTypes.Wal) (Map TxId TxHistoryEntry))
    , _wsUtxo            :: !Utxo
    -- @_wsBalances@ depends on @_wsUtxo@,
    -- it's forbidden to update @_wsBalances@ without @_wsUtxo@
    , _wsBalances        :: !WalletBalances
    , _wsUsedAddresses   :: !CustomAddresses
    , _wsChangeAddresses :: !CustomAddresses
    }

makeClassy ''WalletStorage

instance Default WalletStorage where
    def =
        WalletStorage
        { _wsWalletInfos     = mempty
        , _wsAccountInfos    = mempty
        , _wsProfile         = def
        , _wsReadyUpdates    = mempty
        , _wsTxHistory       = mempty
        , _wsHistoryCache    = mempty
        , _wsUsedAddresses   = mempty
        , _wsChangeAddresses = mempty
        , _wsUtxo            = mempty
        , _wsBalances        = mempty
        }

type Query a = forall m. (MonadReader WalletStorage m) => m a
type Update a = forall m. (MonadState WalletStorage m) => m a

-- | How to lookup addresses of account
data AddressLookupMode
    = Existing  -- ^ fetch only currently existing addresses
    | Deleted   -- ^ fetch only removed addresses
    | Ever      -- ^ fetch both existing and removed addresses

withAccLookupMode :: (Monad m, Monoid a) => AddressLookupMode -> m a -> m a -> m a
withAccLookupMode Existing existing _       = existing
withAccLookupMode Deleted  _        deleted = deleted
withAccLookupMode Ever     existing deleted = mappend <$> existing <*> deleted

-- | Specifies special category of addresses which are stored in base.
data CustomAddressType
    = UsedAddr
    | ChangeAddr

customAddressL :: CustomAddressType -> Lens' WalletStorage CustomAddresses
customAddressL UsedAddr   = wsUsedAddresses
customAddressL ChangeAddr = wsChangeAddresses

-- | Keeps existing and pseudo-removed entries, e.g. addresses.
data CurrentAndRemoved a = CurrentAndRemoved
    { getCurrent :: a
    , getRemoved :: a
    }

getProfile :: Query WebTypes.CProfile
getProfile = view wsProfile

setProfile :: WebTypes.CProfile -> Update ()
setProfile cProfile = wsProfile .= cProfile

doesAccountExist :: WebTypes.AccountId -> Query Bool
doesAccountExist accId = view $ wsAccountInfos . at accId . to isJust

getAccountIds :: Query [WebTypes.AccountId]
getAccountIds = HM.keys <$> view wsAccountInfos

getAccountMetas :: Query [WebTypes.CAccountMeta]
getAccountMetas = map (view aiMeta) . toList <$> view wsAccountInfos

getAccountMeta :: WebTypes.AccountId -> Query (Maybe WebTypes.CAccountMeta)
getAccountMeta accId = preview (wsAccountInfos . ix accId . aiMeta)

getAccountAddrMaps :: WebTypes.AccountId -> Query (CurrentAndRemoved CAddresses)
getAccountAddrMaps accId = do
    getCurrent <- getMap aiAddresses
    getRemoved <- getMap aiRemovedAddresses
    return CurrentAndRemoved{..}
  where
    getMap aiLens = fmap (fromMaybe mempty) $ preview $ wsAccountInfos . ix accId . aiLens

getWalletMetas :: Query [WebTypes.CWalletMeta]
getWalletMetas = toList . fmap _wiMeta . HM.filter _wiIsReady <$> view wsWalletInfos

getWalletMetaIncludeUnready :: Bool -> WebTypes.CId WebTypes.Wal -> Query (Maybe WebTypes.CWalletMeta)
getWalletMetaIncludeUnready includeUnready cWalId = fmap _wiMeta . applyFilter <$> preview (wsWalletInfos . ix cWalId)
  where
    applyFilter xs = if includeUnready then xs else filterMaybe _wiIsReady xs
    filterMaybe :: (a -> Bool) -> Maybe a -> Maybe a
    filterMaybe p ma = ma >>= \a -> guard (p a) >> return a

getWalletMeta :: WebTypes.CId WebTypes.Wal -> Query (Maybe WebTypes.CWalletMeta)
getWalletMeta = getWalletMetaIncludeUnready False

getWalletPassLU :: WebTypes.CId WebTypes.Wal -> Query (Maybe WebTypes.PassPhraseLU)
getWalletPassLU cWalId = preview (wsWalletInfos . ix cWalId . wiPassphraseLU)

getWalletSyncTip :: WebTypes.CId WebTypes.Wal -> Query (Maybe WalletTip)
getWalletSyncTip cWalId = preview (wsWalletInfos . ix cWalId . wiSyncTip)

getWalletAddresses :: Query [WebTypes.CId WebTypes.Wal]
getWalletAddresses =
    map fst . sortOn (view wiCreationTime . snd) . filter (view wiIsReady . snd) . HM.toList <$>
    view wsWalletInfos

getAccountWAddresses :: AddressLookupMode
                     -> WebTypes.AccountId
                     -> Query (Maybe [AddressInfo])
getAccountWAddresses mode accId =
    withAccLookupMode mode (fetch aiAddresses) (fetch aiRemovedAddresses)
  where
    fetch :: MonadReader WalletStorage m => Lens' AccountInfo CAddresses -> m (Maybe [AddressInfo])
    fetch which = fmap HM.elems <$> preview (wsAccountInfos . ix accId . which)

getWAddresses :: AddressLookupMode
              -> WebTypes.CId WebTypes.Wal
              -> Query [AddressInfo]
getWAddresses mode wid =
    withAccLookupMode mode (fetch aiAddresses) (fetch aiRemovedAddresses)
  where
    fetch :: MonadReader WalletStorage m => Lens' AccountInfo CAddresses -> m [AddressInfo]
    fetch which = do
      accs <- HM.filterWithKey (\k _ -> WebTypes.aiWId k == wid) <$> view wsAccountInfos
      return $ HM.elems =<< accs ^.. traverse . which

doesWAddressExist :: AddressLookupMode -> WAddressMeta -> Query Bool
doesWAddressExist mode addrMeta@(view wamAccount -> wAddr) =
    getAny <$>
        withAccLookupMode mode (exists aiAddresses) (exists aiRemovedAddresses)
  where
    exists :: Lens' AccountInfo CAddresses -> Query Any
    exists which =
        Any . isJust <$>
        preview (wsAccountInfos . ix wAddr . which . ix (addrMeta ^. wamAddress))

getTxMeta :: WebTypes.CId WebTypes.Wal -> WebTypes.CTxId -> Query (Maybe WebTypes.CTxMeta)
getTxMeta cid ctxId = preview $ wsTxHistory . ix cid . ix ctxId

getWalletTxHistory :: WebTypes.CId WebTypes.Wal -> Query (Maybe [WebTypes.CTxMeta])
getWalletTxHistory cWalId = toList <<$>> preview (wsTxHistory . ix cWalId)

getWalletUtxo :: Query Utxo
getWalletUtxo = view wsUtxo

getWalletBalancesAndUtxo :: Query WalBalancesAndUtxo
getWalletBalancesAndUtxo = (,) <$> view wsBalances <*> view wsUtxo

updateWalletBalancesAndUtxo :: UtxoModifier -> Update ()
updateWalletBalancesAndUtxo modifier = do
    balAndUtxo <- (,) <$> use wsBalances <*> use wsUtxo
    wsBalances .= applyUtxoModToAddrCoinMap modifier balAndUtxo
    wsUtxo %= MM.modifyMap modifier

setWalletUtxo :: Utxo -> Update ()
setWalletUtxo utxo = do
    wsUtxo .= utxo
    wsBalances .= utxoToAddressCoinMap utxo

getUpdates :: Query [WebTypes.CUpdateInfo]
getUpdates = view wsReadyUpdates

getNextUpdate :: Query (Maybe WebTypes.CUpdateInfo)
getNextUpdate = preview (wsReadyUpdates . _head)

getHistoryCache :: WebTypes.CId WebTypes.Wal -> Query (Maybe (Map TxId TxHistoryEntry))
getHistoryCache cWalId = view $ wsHistoryCache . at cWalId

getCustomAddresses :: CustomAddressType -> Query [Address]
getCustomAddresses t = HM.keys <$> view (customAddressL t)

getCustomAddress :: CustomAddressType -> Address -> Query (Maybe HeaderHash)
getCustomAddress t addr = view $ customAddressL t . at addr

getPendingTxs :: Query [PendingTx]
getPendingTxs = asks $ toListOf (wsWalletInfos . traversed . wsPendingTxs . traversed)

getWalletPendingTxs :: WebTypes.CId WebTypes.Wal -> Query (Maybe [PendingTx])
getWalletPendingTxs wid =
    preview $ wsWalletInfos . ix wid . wsPendingTxs . to toList

getPendingTx :: WebTypes.CId WebTypes.Wal -> TxId -> Query (Maybe PendingTx)
getPendingTx wid txId = preview $ wsWalletInfos . ix wid . wsPendingTxs . ix txId

addCustomAddress :: CustomAddressType -> (Address, HeaderHash) -> Update Bool
addCustomAddress t (addr, hh) = fmap isJust $ customAddressL t . at addr <<.= Just hh

removeCustomAddress :: CustomAddressType -> (Address, HeaderHash) -> Update Bool
removeCustomAddress t (addr, hh) = do
    mhh' <- use $ customAddressL t . at addr
    let exists = mhh' == Just hh
    when exists $
        customAddressL t . at addr .= Nothing
    return exists

createAccount :: WebTypes.AccountId -> WebTypes.CAccountMeta -> Update ()
createAccount accId cAccMeta =
    wsAccountInfos . at accId %= Just . fromMaybe (AccountInfo cAccMeta mempty mempty 0)

-- `isReady` is marked False when an additional step such as syncing is still needed.
createWallet :: WebTypes.CId WebTypes.Wal -> WebTypes.CWalletMeta -> Bool -> POSIXTime -> Update ()
createWallet cWalId cWalMeta isReady curTime = do
    let info = WalletInfo cWalMeta curTime curTime NotSynced mempty isReady
    wsWalletInfos . at cWalId %= (<|> Just info)

addWAddress :: WAddressMeta -> Update ()
addWAddress addrMeta = do
    let accInfo :: Traversal' WalletStorage AccountInfo
        accInfo = wsAccountInfos . ix (addrMeta ^. wamAccount)
        addr = addrMeta ^. wamAddress
    whenJustM (preuse accInfo) $ \info -> do
        let mAddr = info ^. aiAddresses . at addr
        when (isNothing mAddr) $ do
            accInfo . aiUnusedKey += 1
            let key = info ^. aiUnusedKey
            accInfo . aiAddresses . at addr ?= AddressInfo addrMeta key

-- see also 'removeWAddress'
addRemovedAccount :: WAddressMeta -> Update ()
addRemovedAccount addrMeta = do
    let accInfo :: Traversal' WalletStorage AccountInfo
        accInfo = wsAccountInfos . ix (view wamAccount addrMeta)
        addr = addrMeta ^. wamAddress
    whenJustM (preuse (accInfo . aiUnusedKey)) $ \key -> do
        accInfo . aiUnusedKey += 1
        accInfo . aiAddresses        . at addr .= Nothing
        accInfo . aiRemovedAddresses . at addr ?= AddressInfo addrMeta key

setAccountMeta :: WebTypes.AccountId -> WebTypes.CAccountMeta -> Update ()
setAccountMeta accId cAccMeta = wsAccountInfos . ix accId . aiMeta .= cAccMeta

setWalletMeta :: WebTypes.CId WebTypes.Wal -> WebTypes.CWalletMeta -> Update ()
setWalletMeta cWalId cWalMeta = wsWalletInfos . ix cWalId . wiMeta .= cWalMeta

setWalletReady :: WebTypes.CId WebTypes.Wal -> Bool -> Update ()
setWalletReady cWalId isReady = wsWalletInfos . ix cWalId . wiIsReady .= isReady

setWalletPassLU :: WebTypes.CId WebTypes.Wal -> WebTypes.PassPhraseLU -> Update ()
setWalletPassLU cWalId passLU = wsWalletInfos . ix cWalId . wiPassphraseLU .= passLU

setWalletSyncTip :: WebTypes.CId WebTypes.Wal -> HeaderHash -> Update ()
setWalletSyncTip cWalId hh = wsWalletInfos . ix cWalId . wiSyncTip .= SyncedWith hh

addWalletTxHistory :: WebTypes.CId WebTypes.Wal -> WebTypes.CTxId -> WebTypes.CTxMeta -> Update ()
addWalletTxHistory cWalId cTxId cTxMeta =
    wsTxHistory . at cWalId . non' _Empty . at cTxId ?= cTxMeta

setWalletTxHistory :: WebTypes.CId WebTypes.Wal -> [(WebTypes.CTxId, WebTypes.CTxMeta)] -> Update ()
setWalletTxHistory cWalId cTxs = mapM_ (uncurry $ addWalletTxHistory cWalId) cTxs

-- FIXME: this will be removed later (temporary solution)
addOnlyNewTxMeta :: WebTypes.CId WebTypes.Wal -> WebTypes.CTxId -> WebTypes.CTxMeta -> Update ()
addOnlyNewTxMeta cWalId cTxId cTxMeta =
    -- Double nested HashMap update (if either or both of cWalId, cTxId don't exist, they will be created)
    wsTxHistory . at cWalId . non' _Empty . at cTxId %= Just . fromMaybe cTxMeta

-- NOTE: sets transaction meta only for transactions ids that are already seen
setWalletTxMeta :: WebTypes.CId WebTypes.Wal -> WebTypes.CTxId -> WebTypes.CTxMeta -> Update ()
setWalletTxMeta cWalId cTxId cTxMeta =
    wsTxHistory . ix cWalId . at cTxId %= ($> cTxMeta)

removeTxMetas :: WebTypes.CId WebTypes.Wal -> Update ()
removeTxMetas cWalId = wsTxHistory . at cWalId .= Nothing

addOnlyNewTxMetas :: WebTypes.CId WebTypes.Wal -> [(WebTypes.CTxId, WebTypes.CTxMeta)] -> Update ()
addOnlyNewTxMetas = mapM_ . uncurry . addOnlyNewTxMeta

removeWalletTxMetas :: WebTypes.CId WebTypes.Wal -> [WebTypes.CTxId] -> Update ()
removeWalletTxMetas cWalId cTxs =
    wsTxHistory . at cWalId . non' _Empty %= flip (foldr HM.delete) cTxs

removeWallet :: WebTypes.CId WebTypes.Wal -> Update ()
removeWallet cWalId = wsWalletInfos . at cWalId .= Nothing

removeHistoryCache :: WebTypes.CId WebTypes.Wal -> Update ()
removeHistoryCache cWalId = wsHistoryCache . at cWalId .= Nothing

removeAccount :: WebTypes.AccountId -> Update ()
removeAccount accId = wsAccountInfos . at accId .= Nothing

-- see also 'addRemovedAccount'
removeWAddress :: WAddressMeta -> Update ()
removeWAddress addrMeta@(view wamAccount -> accId) = do
    let addrId = addrMeta ^. wamAddress
    -- If the address exists, move it to 'addressesRemoved'
    whenJustM (preuse (accAddresses accId . ix addrId)) $ \addressInfo -> do
        accAddresses        accId . at addrId .= Nothing
        accRemovedAddresses accId . at addrId .= Just addressInfo
  where
    accAddresses        accId' = wsAccountInfos . ix accId' . aiAddresses
    accRemovedAddresses accId' = wsAccountInfos . ix accId' . aiRemovedAddresses

totallyRemoveWAddress :: WAddressMeta -> Update ()
totallyRemoveWAddress addrMeta@(view wamAccount -> accId) = do
    wsAccountInfos . ix accId . aiAddresses        . at (addrMeta ^. wamAddress) .= Nothing
    wsAccountInfos . ix accId . aiRemovedAddresses . at (addrMeta ^. wamAddress) .= Nothing

addUpdate :: WebTypes.CUpdateInfo -> Update ()
addUpdate ui = wsReadyUpdates %= (++ [ui])

removeNextUpdate :: Update ()
removeNextUpdate = wsReadyUpdates %= drop 1

testReset :: Update ()
testReset = put def

-- Legacy transaction, no longer used. For existing Db tx logs only. Now use
-- 'removeHistoryCache', 'insertIntoHistoryCache' or 'removeFromHistoryCache'
updateHistoryCache :: WebTypes.CId WebTypes.Wal -> [TxHistoryEntry] -> Update ()
updateHistoryCache cWalId cTxs =
    wsHistoryCache . at cWalId ?= txHistoryListToMap cTxs

insertIntoHistoryCache :: WebTypes.CId WebTypes.Wal -> Map TxId TxHistoryEntry -> Update ()
insertIntoHistoryCache cWalId cTxs =
    wsHistoryCache . at cWalId . non' _Empty %= (cTxs `M.union`)

removeFromHistoryCache :: WebTypes.CId WebTypes.Wal -> Map TxId () -> Update ()
removeFromHistoryCache cWalId cTxs =
    wsHistoryCache . at cWalId . non' _Empty %= (`M.difference` cTxs)

-- This shouldn't be able to create new transaction.
-- NOTE: If you're going to use this function, make sure 'casPtxCondition'
-- doesn't fit your purposes better
setPtxCondition :: WebTypes.CId WebTypes.Wal -> TxId -> PtxCondition -> Update ()
setPtxCondition wid txId cond =
    wsWalletInfos . ix wid . wsPendingTxs . ix txId . ptxCond .= cond

-- | Compare-and-set version of 'setPtxCondition'.
-- Returns 'True' if transaction existed and modification was applied.
casPtxCondition :: WebTypes.CId WebTypes.Wal -> TxId -> PtxCondition -> PtxCondition -> Update Bool
casPtxCondition wid txId expectedCond newCond = do
    oldCond <- preuse $ wsWalletInfos . ix wid . wsPendingTxs . ix txId . ptxCond
    let success = oldCond == Just expectedCond
    when success $ setPtxCondition wid txId newCond
    return success

data PtxMetaUpdate
    = PtxIncSubmitTiming
    | PtxResetSubmitTiming SlotId
    | PtxMarkAcknowledged

-- | For simple atomic updates of meta info
ptxUpdateMeta :: HasProtocolConstants => WebTypes.CId WebTypes.Wal -> TxId -> PtxMetaUpdate -> Update ()
ptxUpdateMeta wid txId updType =
    wsWalletInfos . ix wid . wsPendingTxs . ix txId %=
        case updType of
            PtxIncSubmitTiming ->
                ptxSubmitTiming %~ incPtxSubmitTimingPure
            PtxResetSubmitTiming curSlot ->
                ptxSubmitTiming .~ mkPtxSubmitTiming curSlot
            PtxMarkAcknowledged ->
                ptxMarkAcknowledgedPure

cancelApplyingPtxs :: Update ()
cancelApplyingPtxs =
    wsWalletInfos . traversed .
    wsPendingTxs . traversed %= cancelApplyingPtx

cancelSpecificApplyingPtx :: TxId -> Update ()
cancelSpecificApplyingPtx txId =
    wsWalletInfos . traversed .
    wsPendingTxs . ix txId %= cancelApplyingPtx

addOnlyNewPendingTx :: PendingTx -> Update ()
addOnlyNewPendingTx ptx =
    wsWalletInfos . ix (_ptxWallet ptx) .
    wsPendingTxs . at (_ptxTxId ptx) %= (<|> Just ptx)


getWalletStorage :: Query WalletStorage
getWalletStorage = ask

-- | Flushes data in wallet storage
-- Preserves all metadata, wallets, accounts and addresses
-- Flushes all data that can be rebuild from blockchain (tx history and etc.)
flushWalletStorage :: Update ()
flushWalletStorage = modify flushDo
  where
    flushDo ws = ws
        { _wsWalletInfos = flushWalletInfo <$> _wsWalletInfos ws
        , _wsHistoryCache = HM.empty
        , _wsUtxo = M.empty
        , _wsUsedAddresses = HM.empty
        , _wsChangeAddresses = HM.empty
        }
    flushWalletInfo wi = wi { _wiSyncTip = NotSynced
                            , _wiIsReady = False
                            }

deriveSafeCopySimple 0 'base ''WebTypes.CCoin
deriveSafeCopySimple 0 'base ''WebTypes.CProfile
deriveSafeCopySimple 0 'base ''WebTypes.CHash
deriveSafeCopySimple 0 'base ''WebTypes.CId
deriveSafeCopySimple 0 'base ''WebTypes.Wal
deriveSafeCopySimple 0 'base ''WebTypes.Addr
deriveSafeCopySimple 0 'base ''BackupPhrase
deriveSafeCopySimple 0 'base ''WebTypes.AccountId
deriveSafeCopySimple 0 'base ''WebTypes.CWAddressMeta
deriveSafeCopySimple 0 'base ''WebTypes.CWalletAssurance
deriveSafeCopySimple 0 'base ''WebTypes.CAccountMeta
deriveSafeCopySimple 0 'base ''WebTypes.CWalletMeta
deriveSafeCopySimple 0 'base ''WebTypes.CTxId
deriveSafeCopySimple 0 'base ''Timestamp
deriveSafeCopySimple 0 'base ''TxHistoryEntry
deriveSafeCopySimple 0 'base ''WebTypes.CTxMeta
deriveSafeCopySimple 0 'base ''WebTypes.CUpdateInfo
deriveSafeCopySimple 0 'base ''AddressLookupMode
deriveSafeCopySimple 0 'base ''CustomAddressType
deriveSafeCopySimple 0 'base ''CurrentAndRemoved
deriveSafeCopySimple 0 'base ''TxAux
deriveSafeCopySimple 0 'base ''PtxCondition
deriveSafeCopySimple 0 'base ''PtxSubmitTiming
deriveSafeCopySimple 0 'base ''PtxMetaUpdate
deriveSafeCopySimple 0 'base ''PendingTx
deriveSafeCopySimple 0 'base ''WAddressMeta
deriveSafeCopySimple 0 'base ''WalletTip
deriveSafeCopySimple 0 'base ''WalletInfo

-- Legacy versions, for migrations

data AddressInfo_v0 = AddressInfo_v0
    { _v0_adiCWAddressMeta :: !WebTypes.CWAddressMeta
    , _v0_adiSortingKey    :: !AddressSortingKey
    }

type CAddresses_v0 = HashMap (WebTypes.CId WebTypes.Addr) AddressInfo_v0
type CustomAddresses_v0 = HashMap (WebTypes.CId WebTypes.Addr) HeaderHash

data AccountInfo_v0 = AccountInfo_v0
    { _v0_aiMeta             :: !WebTypes.CAccountMeta
    , _v0_aiAddresses        :: !CAddresses_v0
    , _v0_aiRemovedAddresses :: !CAddresses_v0
    , _v0_aiUnusedKey        :: !AddressSortingKey
    }

data WalletStorage_v0 = WalletStorage_v0
    { _v0_wsWalletInfos     :: !(HashMap (WebTypes.CId WebTypes.Wal) WalletInfo)
    , _v0_wsAccountInfos    :: !(HashMap WebTypes.AccountId AccountInfo_v0)
    , _v0_wsProfile         :: !WebTypes.CProfile
    , _v0_wsReadyUpdates    :: [WebTypes.CUpdateInfo]
    , _v0_wsTxHistory       :: !(HashMap (WebTypes.CId WebTypes.Wal) (HashMap WebTypes.CTxId WebTypes.CTxMeta))
    , _v0_wsHistoryCache    :: !(HashMap (WebTypes.CId WebTypes.Wal) [TxHistoryEntry])
    , _v0_wsUtxo            :: !Utxo
    , _v0_wsUsedAddresses   :: !CustomAddresses_v0
    , _v0_wsChangeAddresses :: !CustomAddresses_v0
    }

data WalletStorage_v1 = WalletStorage_v1
    { _v1_wsWalletInfos     :: !(HashMap (WebTypes.CId WebTypes.Wal) WalletInfo)
    , _v1_wsAccountInfos    :: !(HashMap WebTypes.AccountId AccountInfo_v0)
    , _v1_wsProfile         :: !WebTypes.CProfile
    , _v1_wsReadyUpdates    :: [WebTypes.CUpdateInfo]
    , _v1_wsTxHistory       :: !(HashMap (WebTypes.CId WebTypes.Wal) (HashMap WebTypes.CTxId WebTypes.CTxMeta))
    , _v1_wsHistoryCache    :: !(HashMap (WebTypes.CId WebTypes.Wal) (Map TxId TxHistoryEntry))
    , _v1_wsUtxo            :: !Utxo
    , _v1_wsUsedAddresses   :: !CustomAddresses_v0
    , _v1_wsChangeAddresses :: !CustomAddresses_v0
    }

data WalletStorage_v2 = WalletStorage_v2
    { _v2_wsWalletInfos     :: !(HashMap (WebTypes.CId WebTypes.Wal) WalletInfo)
    , _v2_wsAccountInfos    :: !(HashMap WebTypes.AccountId AccountInfo_v0)
    , _v2_wsProfile         :: !WebTypes.CProfile
    , _v2_wsReadyUpdates    :: [WebTypes.CUpdateInfo]
    , _v2_wsTxHistory       :: !(HashMap (WebTypes.CId WebTypes.Wal) (HashMap WebTypes.CTxId WebTypes.CTxMeta))
    , _v2_wsHistoryCache    :: !(HashMap (WebTypes.CId WebTypes.Wal) (Map TxId TxHistoryEntry))
    , _v2_wsUtxo            :: !Utxo
    -- @_wsBalances@ depends on @_wsUtxo@,
    -- it's forbidden to update @_wsBalances@ without @_wsUtxo@
    , _v2_wsBalances        :: !WalletBalances
    , _v2_wsUsedAddresses   :: !CustomAddresses_v0
    , _v2_wsChangeAddresses :: !CustomAddresses_v0
    }

deriveSafeCopySimple 0 'base ''AddressInfo_v0
deriveSafeCopySimple 1 'extension ''AddressInfo

deriveSafeCopySimple 0 'base ''AccountInfo_v0
deriveSafeCopySimple 1 'extension ''AccountInfo

deriveSafeCopySimple 0 'base ''WalletStorage_v0
deriveSafeCopySimple 1 'extension ''WalletStorage_v1
deriveSafeCopySimple 2 'extension ''WalletStorage_v2
deriveSafeCopySimple 3 'extension ''WalletStorage

-- | Unsafe address conversion for use in migration. This will throw an error if
--   the address cannot be migrated.
unsafeCIdToAddress :: WebTypes.CId WebTypes.Addr -> Address
unsafeCIdToAddress cId = case WebTypes.cIdToAddress cId of
    Left err -> error $ "unsafeCIdToAddress: " <> err
    Right x  -> x

instance Migrate AddressInfo where
    type MigrateFrom AddressInfo = AddressInfo_v0
    migrate AddressInfo_v0{..} = AddressInfo
        { adiWAddressMeta = cwamToWam _v0_adiCWAddressMeta
        , adiSortingKey = _v0_adiSortingKey
        }
      where
        cwamToWam (WebTypes.CWAddressMeta wid accIdx addrIdx cAddr) =
            WAddressMeta wid accIdx addrIdx $ unsafeCIdToAddress cAddr

instance Migrate AccountInfo where
    type MigrateFrom AccountInfo = AccountInfo_v0
    migrate AccountInfo_v0{..} = AccountInfo
        { _aiMeta = _v0_aiMeta
        , _aiAddresses = mapAddrs _v0_aiAddresses
        , _aiRemovedAddresses = mapAddrs _v0_aiRemovedAddresses
        , _aiUnusedKey = _v0_aiUnusedKey
        }
      where
        mapAddrs =
            HM.fromList
          . fmap (unsafeCIdToAddress *** migrate)
          . HM.toList

instance Migrate WalletStorage_v1 where
    type MigrateFrom WalletStorage_v1 = WalletStorage_v0
    migrate WalletStorage_v0{..} = WalletStorage_v1
        { _v1_wsWalletInfos     = _v0_wsWalletInfos
        , _v1_wsAccountInfos    = _v0_wsAccountInfos
        , _v1_wsProfile         = _v0_wsProfile
        , _v1_wsReadyUpdates    = _v0_wsReadyUpdates
        , _v1_wsTxHistory       = _v0_wsTxHistory
        , _v1_wsHistoryCache    = HM.map txHistoryListToMap _v0_wsHistoryCache
        , _v1_wsUtxo            = _v0_wsUtxo
        , _v1_wsUsedAddresses   = _v0_wsUsedAddresses
        , _v1_wsChangeAddresses = _v0_wsChangeAddresses
        }

instance Migrate WalletStorage_v2 where
    type MigrateFrom WalletStorage_v2 = WalletStorage_v1
    migrate WalletStorage_v1{..} = WalletStorage_v2
        { _v2_wsWalletInfos     = _v1_wsWalletInfos
        , _v2_wsAccountInfos    = _v1_wsAccountInfos
        , _v2_wsProfile         = _v1_wsProfile
        , _v2_wsReadyUpdates    = _v1_wsReadyUpdates
        , _v2_wsTxHistory       = _v1_wsTxHistory
        , _v2_wsHistoryCache    = _v1_wsHistoryCache
        , _v2_wsUtxo            = _v1_wsUtxo
        , _v2_wsBalances        = utxoToAddressCoinMap _v1_wsUtxo
        , _v2_wsUsedAddresses   = _v1_wsUsedAddresses
        , _v2_wsChangeAddresses = _v1_wsChangeAddresses
        }

instance Migrate WalletStorage where
    type MigrateFrom WalletStorage = WalletStorage_v2
    migrate WalletStorage_v2{..} = WalletStorage
        { _wsWalletInfos     = _v2_wsWalletInfos
        , _wsAccountInfos    = fmap migrate _v2_wsAccountInfos
        , _wsProfile         = _v2_wsProfile
        , _wsReadyUpdates    = _v2_wsReadyUpdates
        , _wsTxHistory       = _v2_wsTxHistory
        , _wsHistoryCache    = _v2_wsHistoryCache
        , _wsUtxo            = _v2_wsUtxo
        , _wsBalances        = _v2_wsBalances
        , _wsUsedAddresses   = mapAddrKeys _v2_wsUsedAddresses
        , _wsChangeAddresses = mapAddrKeys _v2_wsChangeAddresses
        }
      where
        mapAddrKeys = HM.fromList . fmap (first unsafeCIdToAddress) . HM.toList

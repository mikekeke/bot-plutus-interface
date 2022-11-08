module BotPlutusInterface.Constraints (submitBpiTxConstraintsWith, mustValidateInFixed, BpiConstraint) where

import Control.Lens (re, (^.))
import Control.Monad (foldM, forM_)
import Data.Kind (Type)
import Data.Row (Row)
import Data.Text (Text, pack)
import Ledger (CardanoTx, POSIXTimeRange, Tx (txValidRange))
import Ledger.Constraints (ScriptLookups, TxConstraint (MustValidateIn), TxConstraints (txConstraints), UnbalancedTx (UnbalancedEmulatorTx))
import Ledger.Slot (SlotRange)
import Ledger.TimeSlot (SlotConversionError)
import Ledger.Typed.Scripts (DatumType, RedeemerType)
import Plutus.Contract (AsContractError (_OtherContractError), Contract, mkTxConstraints, submitUnbalancedTx, throwError)
import Plutus.Contract.Effects (PABReq (PosixTimeRangeToContainedSlotRangeReq), _PosixTimeRangeToContainedSlotRangeResp)
import Plutus.Contract.Request (pabReq)
import PlutusTx.IsData.Class (FromData, ToData)
import Prelude

-- TODO: add MustMintValueWithReferencePolicy
data BpiConstraint
  = MustValidateInFixed POSIXTimeRange

mustValidateInFixed :: POSIXTimeRange -> [BpiConstraint]
mustValidateInFixed = pure . MustValidateInFixed

flagBannedConstraints ::
  forall (a :: Type) (w :: Type) (s :: Row Type) (e :: Type).
  AsContractError e =>
  ScriptLookups a -> -- We use this only as a proxy to avoid ambiguous types
  TxConstraints (RedeemerType a) (DatumType a) ->
  Contract w s e ()
flagBannedConstraints _ constraints =
  forM_ (txConstraints constraints) $ \case
    MustValidateIn _ -> throwAsContractError "MustValidateIn from plutus-apps miscalculates slot ranges, use MustValidateInFixed from BpiConstraint instead."
    _ -> pure ()

throwAsContractError ::
  forall (a :: Type) (w :: Type) (s :: Row Type) (e :: Type).
  AsContractError e =>
  Text ->
  Contract w s e a
throwAsContractError err = throwError $ err ^. re _OtherContractError

submitBpiTxConstraintsWith ::
  forall (a :: Type) (w :: Type) (s :: Row Type) (e :: Type).
  ( ToData (RedeemerType a)
  , FromData (DatumType a)
  , ToData (DatumType a)
  , AsContractError e
  ) =>
  ScriptLookups a ->
  TxConstraints (RedeemerType a) (DatumType a) ->
  [BpiConstraint] ->
  Contract w s e CardanoTx
submitBpiTxConstraintsWith lookups plutusConstraints bpiConstraints =
  flagBannedConstraints lookups plutusConstraints
    >> mkTxConstraints lookups plutusConstraints
    >>= mapBpiConstraints bpiConstraints
    >>= submitUnbalancedTx

posixTimeRangeToContainedSlotRange ::
  forall w s e.
  ( AsContractError e
  ) =>
  POSIXTimeRange ->
  Contract w s e (Either SlotConversionError SlotRange)
posixTimeRangeToContainedSlotRange posixTimeRange = pabReq (PosixTimeRangeToContainedSlotRangeReq posixTimeRange) _PosixTimeRangeToContainedSlotRangeResp

mapBpiConstraints ::
  forall (w :: Type) (s :: Row Type) (e :: Type).
  AsContractError e =>
  [BpiConstraint] ->
  UnbalancedTx ->
  Contract w s e UnbalancedTx
mapBpiConstraints bpiConstraints = mapTx $ \tx -> foldM processBpiConstraint tx bpiConstraints
  where
    mapTx :: (Tx -> Contract w s e Tx) -> UnbalancedTx -> Contract w s e UnbalancedTx
    mapTx f (UnbalancedEmulatorTx tx sigs utxos) = f tx >>= \tx' -> pure $ UnbalancedEmulatorTx tx' sigs utxos
    mapTx _ uTx = pure uTx
    processBpiConstraint :: Tx -> BpiConstraint -> Contract w s e Tx
    processBpiConstraint tx (MustValidateInFixed posixTimeRange) = do
      eSlotRange <- posixTimeRangeToContainedSlotRange posixTimeRange
      slotRange <- either (throwAsContractError . pack . show) pure eSlotRange
      pure tx {txValidRange = slotRange}

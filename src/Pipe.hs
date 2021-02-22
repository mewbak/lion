module Pipe where

import Clash.Prelude
import Control.Lens hiding ( op )
import Control.Monad.RWS
import Data.Monoid.Generic
import Instruction
import Rvfi

data ToPipe = ToPipe
  { _fromRs1 :: BitVector 32
  , _fromRs2 :: BitVector 32
  , _fromMem :: Maybe (BitVector 32)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass NFDataX
makeLenses ''ToPipe

data FromPipe = FromPipe
  { _toMem     :: First (BitVector 32, BitVector 4, Maybe (BitVector 32))
  , _toRs1Addr :: First (Unsigned 5)
  , _toRs2Addr :: First (Unsigned 5)
  , _toRd      :: First (Unsigned 5, BitVector 32)
  , _toRvfi    :: First Rvfi
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass NFDataX
  deriving Semigroup via GenericSemigroup FromPipe
  deriving Monoid via GenericMonoid FromPipe
makeLenses ''FromPipe

data Control = Control
  { _branching :: Maybe (BitVector 32)
  , _fetchNext :: Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass NFDataX
makeLenses ''Control

mkControl :: Control
mkControl = Control
  { _branching = Nothing
  , _fetchNext = False
  }

data Pipe = Pipe
  { _fetchPC  :: BitVector 32

  -- decode stage
  , _dePC     :: BitVector 32
  , _deNPC    :: BitVector 32

  -- execute stage
  , _exIR      :: Maybe ExInstr
  , _exPC      :: BitVector 32
  , _exRs1Zero :: Bool
  , _exRs2Zero :: Bool
  , _exRvfi    :: Rvfi

  -- memory stage
  , _meIR     :: Maybe MeInstr
  , _meRvfi   :: Rvfi

  -- writeback stage
  , _wbIR     :: Maybe WbInstr
  , _wbNRet   :: BitVector 64
  , _wbRvfi   :: Rvfi

  -- pipeline control
  , _control :: Control
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass NFDataX
makeLenses ''Pipe

mkPipe :: Pipe
mkPipe = Pipe
  { _fetchPC  = 0  

  -- decode stage 
  , _dePC     = 0
  , _deNPC    = 0
  
  -- execute stage
  , _exIR      = Nothing
  , _exPC      = 0
  , _exRs1Zero = False
  , _exRs2Zero = False
  , _exRvfi    = mkRvfi

  -- memory stage
  , _meIR     = Nothing
  , _meRvfi   = mkRvfi
 
  -- writeback stage
  , _wbIR   = Nothing
  , _wbNRet = 0
  , _wbRvfi = mkRvfi
  
  -- pipeline control
  , _control = mkControl
  }

pipe 
  :: HiddenClockResetEnable dom
  => Signal dom ToPipe
  -> Signal dom FromPipe
pipe = mealy pipeMealy mkPipe
  where
    pipeMealy s i = let ((), s', o) = runRWS pipeM i s
                    in (s', o) 

pipeM :: RWS ToPipe FromPipe Pipe ()
pipeM = do
  writeback
  memory
  execute
  decode
  fetch

writeback :: RWS ToPipe FromPipe Pipe ()
writeback = use wbIR >>= \instrM ->
  forM_ instrM $ \instr -> do
    wbRvfi.rvfiValid .= True
    wbRvfi.rvfiOrder <~ wbNRet <<+= 1
    case instr of
      WbRegWr rdAddr wr -> do
        wbRvfi.rvfiRdAddr .= rdAddr
        rdData <- wbRvfi.rvfiRdWData <.= guardZero rdAddr wr
        scribe toRd $ First $ Just (rdAddr, rdData)
      WbNop -> return ()
    scribe toRvfi . First . Just =<< use wbRvfi
  where
    guardZero 0 = const 0
    guardZero _ = id

memory :: RWS ToPipe FromPipe Pipe ()
memory = do
  wbRvfi <~ use meRvfi
  use meIR >>= \instrM -> do
    wbIR .= Nothing
    forM_ instrM $ \instr -> do
      case instr of
        MeRegWr rd wr -> wbIR ?= WbRegWr rd wr
        MeNop         -> wbIR ?= WbNop
        MeStore addr mask value -> do
          wbRvfi.rvfiMemAddr .= addr
          wbRvfi.rvfiMemWMask .= mask
          wbRvfi.rvfiMemWData .= value
          scribe toMem $ First $ Just (addr, mask, Just value)
          wbIR ?= WbNop 

execute :: RWS ToPipe FromPipe Pipe ()
execute = do
  meRvfi <~ use exRvfi
  use exIR >>= \instrM -> do
    meIR .= Nothing
    forM_ instrM $ \instr -> do
      pc <- meRvfi.rvfiPcRData <<~ use exPC
      meRvfi.rvfiPcWData .= pc + 4
      rs1Data <- meRvfi.rvfiRs1Data <<~ guardZero exRs1Zero fromRs1
      rs2Data <- meRvfi.rvfiRs2Data <<~ guardZero exRs2Zero fromRs2
      meIR <~ case instr of
        Ex op rd imm -> case op of
          Lui   -> return $ Just $ MeRegWr rd imm
          Auipc -> return $ Just $ MeRegWr rd $ alu Add pc imm
          Jal   -> do
            npc <- meRvfi.rvfiPcWData <.= pc + imm
            meRvfi.rvfiTrap ||= (npc .&. 0x3 /= 0)
            control.branching ?= npc
            return $ Just $ MeRegWr rd $ pc + 4
          Jalr  -> do
            npc <- meRvfi.rvfiPcWData <.= clearBit (rs1Data + imm) 0
            meRvfi.rvfiTrap ||= (npc .&. 0x3 /= 0)
            control.branching ?= npc
            return $ Just $ MeRegWr rd $ pc + 4
        ExBranch op imm -> do
          npc <- if branch op rs1Data rs2Data
                   then do
                     control.branching ?= (pc + imm)
                     return $ pc + imm
                   else return $ pc + 4
          meRvfi.rvfiPcWData .= npc
          meRvfi.rvfiTrap ||= (npc .&. 0x3 /= 0)
          return $ Just MeNop
        ExStore op imm -> do
          let addr = rs1Data + imm
          _    
          return $ Just $ MeStore (rs1Data + imm) _ $ store op rs2Data 
        ExAlu    op rd     -> return $ Just $ MeRegWr rd $ alu op rs1Data rs2Data
        ExAluImm op rd imm -> return $ Just $ MeRegWr rd $ alu op rs1Data imm
  where
    guardZero rsZero rsValue = do
      isZero <- use rsZero
      if isZero
        then return 0
        else view rsValue

decode :: RWS ToPipe FromPipe Pipe ()
decode = do
  exIR   .= Nothing
  exRvfi .= mkRvfi
  memM <- view fromMem
  forM_ memM $ \mem -> do
    control.fetchNext .= True
    use (control.branching) >>= \case
      Just _ -> return () -- insert bubble
      Nothing -> case parseInstr mem of
        Right instr -> do
          exIR ?= instr
          exPC <~ use dePC
          exRvfi.rvfiInsn .= mem
          scribe toRs1Addr . First . Just =<< exRvfi.rvfiRs1Addr <.= sliceRs1 mem
          scribe toRs2Addr . First . Just =<< exRvfi.rvfiRs2Addr <.= sliceRs2 mem
        Left _ -> exRvfi.rvfiTrap .= True
  
fetch :: RWS ToPipe FromPipe Pipe ()
fetch = do
  scribe toMem . First . Just =<< uses fetchPC (,Nothing)
  next <- use $ control.fetchNext
  when next $ do
    control.fetchNext .= False -- reset fetch next flag
    use (control.branching) >>= \case
      Just npc -> do
        control.branching .= Nothing -- reset branching flag
        dePC <~ fetchPC <.= npc
      Nothing -> dePC <~ fetchPC <+= 4      -- increment PC




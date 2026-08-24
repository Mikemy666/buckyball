package framework.memdomain.frontend.mem.prefetch

import chisel3._
import chisel3.util._
import framework.top.GlobalConfig

class PrefetchDescriptor(val b: GlobalConfig) extends Bundle {
  val descriptorId = UInt(log2Up(b.frontend.rob_entries).W)
  val address      = UInt(b.memDomain.memAddrLen.W)
  val beats        = UInt(8.W)
  val chunkMask    = UInt(4.W)
  val windowMask   = UInt(4.W)
  val eligibleMask = UInt(b.memDomain.bankNum.W)
}

class PrefetchDecision(val b: GlobalConfig) extends Bundle {
  val descriptorId = UInt(log2Up(b.frontend.rob_entries).W)
  val address      = UInt(b.memDomain.memAddrLen.W)
  val beats        = UInt(8.W)
  val chunkIdx     = UInt(2.W)
  val windowIdx    = UInt(2.W)
  val group        = UInt(log2Up(b.memDomain.bankNum).W)
}

/**
 * PIVOT Section III-B pressure-aware prefetch policy.
 *
 * One bank group is sampled per cycle, then one (chunk, window, group)
 * candidate is evaluated per cycle. This intentionally shares the pressure
 * and score datapaths instead of building a sorting network or a parallel
 * C x W x G evaluator.
 */
class AdaptivePrefetchController(val b: GlobalConfig) extends Module {
  private val p           = b.memDomain.adaptivePrefetch
  private val numGroups   = b.memDomain.bankNum
  private val groupWidth  = log2Up(numGroups)
  private val topWidth    = log2Up(math.max(p.topK, 2))
  private val monMax      = (BigInt(1) << p.monitorWidth) - 1
  private val pressureMax = (BigInt(1) << p.pressureWidth) - 1
  private val emaMax      = (BigInt(1) << p.emaWidth) - 1

  require(p.topK >= 1 && p.topK <= numGroups)
  require(p.descriptorDepth >= 1 && p.descriptorDepth <= 4)
  require(p.monitorWidth >= 2 && p.pressureWidth >= p.monitorWidth + 2)
  require(p.scoreWidth >= p.pressureWidth + 2)
  require(p.emaShift > 0 && p.emaShift < p.emaWidth)
  require(p.coverageThreshold >= 0 && p.coverageThreshold <= emaMax)
  require(p.accuracyThreshold >= 0 && p.accuracyThreshold <= emaMax)

  val io = IO(new Bundle {
    val descriptor = Flipped(Decoupled(new PrefetchDescriptor(b)))
    val decision   = Decoupled(new PrefetchDecision(b))
    val suppressed = Output(Bool())

    // Events are taken from the existing DMA BankWrite channel.
    val bankActivityValid = Input(Bool())
    val bankActivityGroup = Input(UInt(groupWidth.W))
    val bankConflict      = Input(Bool())
    val residencyValid    = Input(Bool())
    val residencyGroup    = Input(UInt(groupWidth.W))

    // Binary event samples; EMA uses shift/add only.
    val coverageSampleValid = Input(Bool())
    val coverageSample      = Input(Bool())
    val accuracySampleValid = Input(Bool())
    val accuracySample      = Input(Bool())
  })

  val descriptorQ = Module(new Queue(new PrefetchDescriptor(b), p.descriptorDepth))
  descriptorQ.io.enq <> io.descriptor

  val utilization = RegInit(VecInit(Seq.fill(numGroups)(0.U(p.monitorWidth.W))))
  val conflicts   = RegInit(VecInit(Seq.fill(numGroups)(0.U(p.monitorWidth.W))))
  val residency   = RegInit(VecInit(Seq.fill(numGroups)(0.U(p.monitorWidth.W))))
  val decay       = RegInit(0.U(4.W))

  decay := decay + 1.U
  when(decay === 15.U) {
    for (g <- 0 until numGroups) {
      utilization(g) := utilization(g) >> 1
      conflicts(g)   := conflicts(g) >> 1
      residency(g)   := residency(g) >> 1
    }
  }

  when(io.bankActivityValid) {
    val value = utilization(io.bankActivityGroup)
    utilization(io.bankActivityGroup) := Mux(value === monMax.U, value, value + 1.U)
  }
  when(io.bankConflict) {
    val value = conflicts(io.bankActivityGroup)
    conflicts(io.bankActivityGroup) := Mux(value === monMax.U, value, value + 1.U)
  }
  when(io.residencyValid) {
    val value = residency(io.residencyGroup)
    residency(io.residencyGroup) := Mux(value === monMax.U, value, value + 1.U)
  }

  val coverageEma = RegInit(emaMax.U(p.emaWidth.W))
  val accuracyEma = RegInit(emaMax.U(p.emaWidth.W))

  private def updateEma(reg: UInt, valid: Bool, sample: Bool): Unit = {
    when(valid) {
      when(sample) {
        reg := reg + ((emaMax.U - reg) >> p.emaShift)
      }.otherwise {
        reg := reg - (reg >> p.emaShift)
      }
    }
  }

  updateEma(coverageEma, io.coverageSampleValid, io.coverageSample)
  updateEma(accuracyEma, io.accuracySampleValid, io.accuracySample)

  val sIdle :: sSelect :: sEvaluate :: sIssue :: Nil = Enum(4)
  val state                                          = RegInit(sIdle)

  val active      = Reg(new PrefetchDescriptor(b))
  val scanGroup   = RegInit(0.U(groupWidth.W))
  val topPressure = Reg(Vec(p.topK, UInt(p.pressureWidth.W)))
  val topGroup    = Reg(Vec(p.topK, UInt(groupWidth.W)))
  val topValid    = RegInit(VecInit(Seq.fill(p.topK)(false.B)))

  val evalTop     = RegInit(0.U(topWidth.W))
  val chunkIdx    = RegInit(0.U(2.W))
  val windowIdx   = RegInit(0.U(2.W))
  val foundWindow = RegInit(false.B)
  val bestValid   = RegInit(false.B)
  val bestScore   = Reg(SInt(p.scoreWidth.W))
  val bestChunk   = RegInit(0.U(2.W))
  val bestWindow  = RegInit(0.U(2.W))
  val bestGroup   = RegInit(0.U(groupWidth.W))

  descriptorQ.io.deq.ready := state === sIdle
  io.suppressed            := false.B
  when(state === sIdle && descriptorQ.io.deq.fire) {
    active             := descriptorQ.io.deq.bits
    scanGroup          := 0.U
    topValid.foreach(_ := false.B)
    bestValid          := false.B
    foundWindow        := false.B
    state              := sSelect
  }

  val queuePressure = descriptorQ.io.count
  val rawPressure   = Wire(UInt((p.pressureWidth + 2).W))
  rawPressure := queuePressure +& (utilization(scanGroup) << 1) +&
    conflicts(scanGroup) +& (residency(scanGroup) << 1)
  val scanPressure = Mux(rawPressure > pressureMax.U, pressureMax.U, rawPressure)(p.pressureWidth - 1, 0)

  val betterAt = Wire(Vec(p.topK, Bool()))
  for (k <- 0 until p.topK) {
    betterAt(k) := !topValid(k) || scanPressure < topPressure(k) ||
      (scanPressure === topPressure(k) && scanGroup < topGroup(k))
  }
  val canInsert = betterAt.asUInt.orR
  val insertAt = PriorityEncoder(betterAt)

  when(state === sSelect) {
    when(active.eligibleMask(scanGroup) && canInsert) {
      for (k <- 0 until p.topK) {
        when(insertAt === k.U) {
          for (j <- (k + 1 until p.topK).reverse) {
            topPressure(j) := topPressure(j - 1)
            topGroup(j)    := topGroup(j - 1)
            topValid(j)    := topValid(j - 1)
          }
          topPressure(k) := scanPressure
          topGroup(k) := scanGroup
          topValid(k) := true.B
        }
      }
    }

    when(scanGroup === (numGroups - 1).U) {
      evalTop     := 0.U
      chunkIdx    := 0.U
      windowIdx   := 0.U
      foundWindow := false.B
      state       := sEvaluate
    }.otherwise {
      scanGroup := scanGroup + 1.U
    }
  }

  val chunkBeatsWide = 1.U(active.beats.getWidth.W) << chunkIdx
  val chunkBeats     = Mux(chunkBeatsWide > active.beats, active.beats, chunkBeatsWide)
  val leadCycles     = 2.U(6.W) << windowIdx
  val pfCycles       = 2.U +& chunkBeats +& (topPressure(evalTop) >> 2) +& p.safetyMargin.U
  val windowLegal    = active.windowMask(windowIdx) && leadCycles >= pfCycles
  val chunkLegal     = active.chunkMask(chunkIdx) && chunkBeats =/= 0.U
  val candidateValid = topValid(evalTop) && chunkLegal && windowLegal && !foundWindow

  val hiddenCycles   = Mux(leadCycles > pfCycles, leadCycles - pfCycles, 0.U)
  val residencyCost  = Mux(leadCycles > chunkBeats, leadCycles - chunkBeats, 0.U)
  val candidateScore = Wire(SInt(p.scoreWidth.W))
  candidateScore := ((hiddenCycles << 1).asSInt - residencyCost.asSInt - topPressure(evalTop).asSInt)

  when(state === sEvaluate) {
    when(candidateValid) {
      foundWindow := true.B
      when(!bestValid || candidateScore > bestScore) {
        bestValid  := true.B
        bestScore  := candidateScore
        bestChunk  := chunkIdx
        bestWindow := windowIdx
        bestGroup  := topGroup(evalTop)
      }
    }

    when(windowIdx === 3.U) {
      windowIdx   := 0.U
      foundWindow := false.B
      when(chunkIdx === 3.U) {
        chunkIdx := 0.U
        when(evalTop === (p.topK - 1).U || !topValid(evalTop + 1.U)) {
          when(bestValid && coverageEma >= p.coverageThreshold.U && accuracyEma >= p.accuracyThreshold.U) {
            state := sIssue
          }.otherwise {
            io.suppressed := true.B
            state         := sIdle
          }
        }.otherwise {
          evalTop := evalTop + 1.U
        }
      }.otherwise {
        chunkIdx := chunkIdx + 1.U
      }
    }.otherwise {
      windowIdx := windowIdx + 1.U
    }
  }

  io.decision.valid             := state === sIssue
  io.decision.bits.descriptorId := active.descriptorId
  io.decision.bits.address      := active.address
  io.decision.bits.beats        := Mux((1.U << bestChunk) > active.beats, active.beats, 1.U << bestChunk)
  io.decision.bits.chunkIdx     := bestChunk
  io.decision.bits.windowIdx    := bestWindow
  io.decision.bits.group        := bestGroup

  when(io.decision.fire) {
    state := sIdle
  }
}

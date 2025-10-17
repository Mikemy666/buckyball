package relu

import chisel3._
import chisel3.stage.ChiselStage
import org.scalatest.freespec.AnyFreeSpec
import org.scalatest.matchers.should.Matchers
import org.chipsalliance.cde.config.Parameters
import examples.BuckyBallConfigs.CustomBuckyBallConfig
import examples.toy.balldomain.BallDomain

class ReluBallElab extends AnyFreeSpec with Matchers {
  "Elaborate BallDomain to ensure ReluBall is wired" in {
    implicit val p: Parameters = Parameters.empty
    implicit val b: CustomBuckyBallConfig = examples.CustomBuckyBallConfig()
    // Elaborate only, not running simulation here
    noException shouldBe thrownBy {
      ChiselStage.emitSystemVerilog(new BallDomain)
    }
  }
}

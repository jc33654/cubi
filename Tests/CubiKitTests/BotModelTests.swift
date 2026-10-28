import Testing
@testable import CubiKit

private func run(_ model: inout BotModel, seconds: Double, random: Double = 0.5) {
    var t = 0.0
    while t < seconds {
        model.update(dt: 0.05, random: { random })
        t += 0.05
    }
}

@Test func idleBlinksWithinSixSeconds() {
    var m = BotModel()
    var minOpen = 1.0
    for _ in 0..<120 {
        m.update(dt: 0.05, random: { 0.5 })
        minOpen = min(minOpen, m.pose.eyeOpen)
    }
    #expect(minOpen < 0.5)
}

@Test func sleepingNeverBlinks() {
    var m = BotModel()
    m.setState(.sleeping)
    var minOpen = 1.0
    for _ in 0..<200 {
        m.update(dt: 0.05, random: { 0.0 })
        minOpen = min(minOpen, m.pose.eyeOpen)
    }
    #expect(minOpen == 1)
    #expect(m.pose.eyeShape == .closedArc)
    #expect(m.pose.badge == .zzz)
}

@Test func tiredGetsWorseWithContext() {
    var m = BotModel()
    m.setState(.tired)
    m.contextPercent = 80
    run(&m, seconds: 0.3)
    let mild = m.pose
    m.contextPercent = 95
    let severe = m.pose
    #expect(mild.sweat && severe.sweat)
    #expect(severe.saturation < mild.saturation)
    #expect(mild.pulse == 0)
    #expect(severe.pulse > 0)
}

@Test func errorShakesThenSettles() {
    var m = BotModel()
    run(&m, seconds: 1)
    m.setState(.error)
    m.update(dt: 0.05, random: { 0.5 })
    #expect(m.pose.bodyDX != 0)
    run(&m, seconds: 1)
    #expect(m.pose.bodyDX == 0)
    #expect(m.pose.eyeShape == .flat)
}

@Test func waitingBadgeFollowsKind() {
    var m = BotModel()
    m.waitingBadge = .question
    m.setState(.waiting)
    #expect(m.pose.badge == .question)
    m.waitingBadge = .exclaim
    #expect(m.pose.badge == .exclaim)
}

@Test func thinkingLooksUpRight() {
    var m = BotModel()
    m.setState(.thinking)
    run(&m, seconds: 3)
    #expect(m.pose.lookX > 0.5 && m.pose.lookY > 0.5)
}

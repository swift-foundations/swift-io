import IO_Test_Support
import Testing

extension Basic {
    @Suite(.timeLimit(.minutes(1)))
    struct Test {
        @Suite struct Unit {}
        @Suite struct `Edge Case` {}
        @Suite struct Integration {}
        @Suite(.serialized) struct Performance {}
    }
}

extension Basic.Test.Unit {
    @Test
    func `Basic namespace exists`() {

    }
}

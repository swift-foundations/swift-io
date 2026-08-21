extension Basic {

    public enum Error: Swift.Error, Equatable {

        case brokenPipe

        case timeout

        case cancelled

        case shutdown

        case platform(Error_Primitives.Error.Code)
    }
}

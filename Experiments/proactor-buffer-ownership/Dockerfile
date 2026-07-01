# Swift 6.4-dev nightly matches the ecosystem toolchain. liburing-dev
# provides the io_uring C library this experiment links against.
FROM swiftlang/swift:nightly-main

RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /experiment
COPY . .

RUN swift build -c release && \
    cp "$(swift build -c release --show-bin-path)/experiment" /usr/local/bin/experiment

CMD ["/usr/local/bin/experiment"]

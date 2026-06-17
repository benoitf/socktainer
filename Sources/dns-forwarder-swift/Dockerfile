FROM swift:6.2.3 AS builder
RUN apt-get update -qq && apt-get install -y -qq curl upx > /dev/null && \
    curl -sL "https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz" \
      -o /tmp/sdk.tar.gz && \
    mkdir -p /root/.swiftpm/swift-sdks && \
    tar -xzf /tmp/sdk.tar.gz -C /root/.swiftpm/swift-sdks/ && \
    rm /tmp/sdk.tar.gz
WORKDIR /src
COPY Package.swift .swift-version ./
COPY Sources/ Sources/
RUN swift build --swift-sdk aarch64-swift-linux-musl -c release -Xswiftc -Osize && \
    strip .build/aarch64-swift-linux-musl/release/dns-forwarder && \
    upx --best .build/aarch64-swift-linux-musl/release/dns-forwarder

FROM scratch
COPY --from=builder /src/.build/aarch64-swift-linux-musl/release/dns-forwarder /dns-forwarder
ENTRYPOINT ["/dns-forwarder"]

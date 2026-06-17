// Minimal UDP DNS forwarder for socktainer inter-container DNS.
// Listens on :53 and forwards all queries to the upstream specified
// by DNS_UPSTREAM (the gateway IP on port 2054 where
// SocktainerDNSServer is already listening on the host).

#if canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// SOCK_DGRAM is an enum (__socket_type) on Glibc but Int32 on Darwin/Musl.
#if canImport(Glibc)
  let _SOCK_DGRAM = Int32(SOCK_DGRAM.rawValue)
#else
  let _SOCK_DGRAM = Int32(SOCK_DGRAM)
#endif

let maxDNSSize = 4096
let maxConcurrent: Int32 = 64

@inline(never)
func fatal(_ msg: String) -> Never {
  var buf = Array(msg.utf8) + [0x0A]
  write(STDERR_FILENO, &buf, buf.count)
  exit(1)
}

@inline(never)
func log(_ msg: String) {
  var buf = Array(msg.utf8) + [0x0A]
  write(STDOUT_FILENO, &buf, buf.count)
}

func parseUpstream(_ value: String) -> sockaddr_in {
  guard let colonIdx = value.lastIndex(of: ":") else {
    fatal("DNS_UPSTREAM must be host:port")
  }
  let host = String(value[value.startIndex..<colonIdx])
  guard let port = UInt16(value[value.index(after: colonIdx)...]) else {
    fatal("DNS_UPSTREAM: invalid port")
  }

  var addr = sockaddr_in()
  #if canImport(Darwin)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  #endif
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
    fatal("DNS_UPSTREAM: invalid address '\(host)'")
  }
  return addr
}

nonisolated(unsafe) var active = Int32(0)
nonisolated(unsafe) var activeLock = pthread_mutex_t()

func tryAcquire() -> Bool {
  pthread_mutex_lock(&activeLock)
  defer { pthread_mutex_unlock(&activeLock) }
  if active >= maxConcurrent { return false }
  active += 1
  return true
}

func release() {
  pthread_mutex_lock(&activeLock)
  active -= 1
  pthread_mutex_unlock(&activeLock)
}

struct ForwardArgs {
  var listenFd: Int32
  var clientAddr: sockaddr_in
  var clientLen: socklen_t
  var upstream: sockaddr_in
  var query: UnsafeMutablePointer<UInt8>
  var queryLen: Int
}

func forwardThreadFunc(_ rawArg: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  guard let rawArg else { return nil }
  let argsPtr = rawArg.assumingMemoryBound(to: ForwardArgs.self)
  let args = argsPtr.pointee

  defer {
    args.query.deallocate()
    argsPtr.deallocate()
    release()
  }

  let sockfd = socket(AF_INET, _SOCK_DGRAM, Int32(IPPROTO_UDP))
  guard sockfd >= 0 else { return nil }
  defer { close(sockfd) }

  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  setsockopt(sockfd, Int32(SOL_SOCKET), Int32(SO_RCVTIMEO), &timeout, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(sockfd, Int32(SOL_SOCKET), Int32(SO_SNDTIMEO), &timeout, socklen_t(MemoryLayout<timeval>.size))

  var upstream = args.upstream
  let connected = withUnsafePointer(to: &upstream) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connected == 0 else { return nil }

  let sent = send(sockfd, args.query, args.queryLen, 0)
  guard sent == args.queryLen else { return nil }

  let responseBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: maxDNSSize)
  defer { responseBuf.deallocate() }
  let received = recv(sockfd, responseBuf, maxDNSSize, 0)
  guard received > 0 else { return nil }

  var clientAddr = args.clientAddr
  _ = withUnsafePointer(to: &clientAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      sendto(args.listenFd, responseBuf, received, 0, $0, args.clientLen)
    }
  }

  return nil
}

// --- main ---

guard let upstreamEnv = getenv("DNS_UPSTREAM") else {
  fatal("DNS_UPSTREAM not set")
}
let upstreamStr = String(cString: upstreamEnv)
let upstream = parseUpstream(upstreamStr)

let fd = socket(AF_INET, _SOCK_DGRAM, Int32(IPPROTO_UDP))
guard fd >= 0 else { fatal("socket() failed") }

var yes: Int32 = 1
setsockopt(fd, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), &yes, socklen_t(MemoryLayout<Int32>.size))

var bindAddr = sockaddr_in()
#if canImport(Darwin)
  bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
bindAddr.sin_family = sa_family_t(AF_INET)
bindAddr.sin_port = UInt16(53).bigEndian
bindAddr.sin_addr.s_addr = 0

let bindResult = withUnsafePointer(to: &bindAddr) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
  }
}
guard bindResult == 0 else { fatal("bind() failed on :53") }

pthread_mutex_init(&activeLock, nil)
log("dns-forwarder: listening on :53, upstream \(upstreamStr)")

let recvBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: maxDNSSize)

while true {
  var clientAddr = sockaddr_in()
  var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
  let n = withUnsafeMutablePointer(to: &clientAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
      recvfrom(fd, recvBuf, maxDNSSize, 0, sockPtr, &clientLen)
    }
  }
  guard n > 0 else { continue }

  guard tryAcquire() else { continue }

  let queryBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
  queryBuf.update(from: recvBuf, count: n)

  let argsPtr = UnsafeMutablePointer<ForwardArgs>.allocate(capacity: 1)
  argsPtr.pointee = ForwardArgs(
    listenFd: fd,
    clientAddr: clientAddr,
    clientLen: clientLen,
    upstream: upstream,
    query: queryBuf,
    queryLen: n
  )

  #if canImport(Glibc)
    var thread = pthread_t()
  #else
    var thread: pthread_t? = nil
  #endif
  var attr = pthread_attr_t()
  pthread_attr_init(&attr)
  pthread_attr_setdetachstate(&attr, Int32(PTHREAD_CREATE_DETACHED))
  let rc = pthread_create(&thread, &attr, forwardThreadFunc, argsPtr)
  pthread_attr_destroy(&attr)

  if rc != 0 {
    queryBuf.deallocate()
    argsPtr.deallocate()
    release()
  }
}

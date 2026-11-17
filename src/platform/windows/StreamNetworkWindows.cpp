// Native Winsock transport; wire framing stays compatible with upstream x64.
// GPL-3.0-or-later.
#include "../../stream/StreamNetwork.h"
#include "../../common/Ctx.h"
#include "../../common/exception/ConfigurationException.h"
#include "../../common/exception/NetworkException.h"
#include "../../common/exception/RuntimeException.h"
#include <algorithm>
#include <climits>
#include <cstring>

namespace OpenLogReplicator {
namespace {
    std::string socketError(int error) {
        return "Winsock error " + std::to_string(error) + ": " + std::system_category().message(error);
    }
    void nonblocking(SOCKET socket) {
        u_long enabled = 1;
        if (ioctlsocket(socket, FIONBIO, &enabled) != 0)
            throw NetworkException(10061, socketError(WSAGetLastError()));
    }
    bool ready(SOCKET socket, bool writing, const Ctx* ctx) {
        if (ctx->softShutdown || ctx->hardShutdown)
            throw NetworkException(10056, "stream stopped");
        fd_set available, failed;
        FD_ZERO(&available); FD_ZERO(&failed);
        FD_SET(socket, &available); FD_SET(socket, &failed);
        timeval timeout{0, 100000};
        const int count = select(0, writing ? nullptr : &available, writing ? &available : nullptr, &failed, &timeout);
        if (count == SOCKET_ERROR)
            throw NetworkException(10061, socketError(WSAGetLastError()));
        return count > 0;
    }
}

StreamNetwork::StreamNetwork(Ctx* context, std::string address) : Stream(context, std::move(address)) {}

void StreamNetwork::disconnect() {
    if (socketFD != INVALID_SOCKET) { closesocket(socketFD); socketFD = INVALID_SOCKET; }
    incomingHeaderUsed = 0;
    incomingBody.clear(); incomingBodyUsed = 0;
    incomingLengthKnown = false; completedFrame = false;
}

StreamNetwork::~StreamNetwork() {
    disconnect();
    if (serverFD != INVALID_SOCKET) closesocket(serverFD);
    if (res != nullptr) freeaddrinfo(res);
    if (winsockStarted) WSACleanup();
}

void StreamNetwork::initialize() {
    size_t separator;
    if (!uri.empty() && uri[0] == '[') {
        const auto bracket = uri.find(']');
        if (bracket == std::string::npos || bracket + 1 >= uri.size() || uri[bracket + 1] != ':')
            throw ConfigurationException(30008, "expected [IPv6]:port: " + uri);
        host = uri.substr(1, bracket - 1); separator = bracket + 1;
    } else {
        separator = uri.rfind(':');
        if (separator == std::string::npos)
            throw ConfigurationException(30008, "expected host:port: " + uri);
        host = uri.substr(0, separator);
    }
    port = uri.substr(separator + 1);
    if (port.empty() || port.size() > 5 || port.find_first_not_of("0123456789") != std::string::npos ||
        std::stoul(port) == 0 || std::stoul(port) > 65535)
        throw ConfigurationException(30008, "invalid TCP port: " + uri);
    if (!winsockStarted) {
        WSADATA data{};
        const int error = WSAStartup(MAKEWORD(2, 2), &data);
        if (error) throw RuntimeException(10061, socketError(error));
        winsockStarted = true;
    }
}

std::string StreamNetwork::getName() const { return "Network:" + uri; }

void StreamNetwork::initializeClient() {
    addrinfo hints{}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
    const int lookup = getaddrinfo(host.c_str(), port.c_str(), &hints, &res);
    if (lookup || !res) throw NetworkException(10061, "resolve " + uri + ": " + socketError(lookup));
    int lastError = WSAECONNREFUSED;
    for (auto* address = res; address; address = address->ai_next) {
        socketFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFD == INVALID_SOCKET) { lastError = WSAGetLastError(); continue; }
        nonblocking(socketFD);
        int result = connect(socketFD, address->ai_addr, static_cast<int>(address->ai_addrlen));
        if (result == 0) break;
        lastError = WSAGetLastError();
        if (lastError == WSAEWOULDBLOCK || lastError == WSAEINPROGRESS) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
            while (std::chrono::steady_clock::now() < deadline) {
                if (!ready(socketFD, true, ctx)) continue;
                int size = sizeof(lastError);
                if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&lastError), &size) != 0)
                    lastError = WSAGetLastError();
                break;
            }
            if (lastError == 0) break;
        }
        disconnect();
    }
    freeaddrinfo(res); res = nullptr;
    if (socketFD == INVALID_SOCKET) throw NetworkException(10062, "connect " + uri + ": " + socketError(lastError));
}

void StreamNetwork::initializeServer() {
    addrinfo hints{}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP; hints.ai_flags = AI_PASSIVE;
    const int lookup = getaddrinfo(host.empty() ? nullptr : host.c_str(), port.c_str(), &hints, &res);
    if (lookup || !res) throw RuntimeException(10061, "resolve " + uri + ": " + socketError(lookup));
    int lastError = WSAEADDRNOTAVAIL;
    try {
        for (auto* address = res; address; address = address->ai_next) {
            serverFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
            if (serverFD == INVALID_SOCKET) { lastError = WSAGetLastError(); continue; }
            const BOOL exclusive = 1;
            if (setsockopt(serverFD, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive)) == 0 &&
                bind(serverFD, address->ai_addr, static_cast<int>(address->ai_addrlen)) == 0 && listen(serverFD, 1) == 0) {
                nonblocking(serverFD); break;
            }
            lastError = WSAGetLastError(); closesocket(serverFD); serverFD = INVALID_SOCKET;
        }
    } catch (const NetworkException& error) {
        throw RuntimeException(error.code, error.msg);
    }
    freeaddrinfo(res); res = nullptr;
    if (serverFD == INVALID_SOCKET) throw RuntimeException(10061, "listen " + uri + ": " + socketError(lastError));
}

bool StreamNetwork::isConnected() {
    if (socketFD != INVALID_SOCKET) return true;
    int size = sizeof(address);
    socketFD = accept(serverFD, reinterpret_cast<sockaddr*>(&address), &size);
    if (socketFD == INVALID_SOCKET) {
        const int error = WSAGetLastError();
        if (error == WSAEWOULDBLOCK) { errno = EAGAIN; return false; }
        throw NetworkException(10061, socketError(error));
    }
    nonblocking(socketFD);
    return true;
}

void StreamNetwork::sendMessage(const void* message, uint64_t length) {
    if (socketFD == INVALID_SOCKET) throw NetworkException(10056, "no stream client");
    std::array<uint8_t, 12> header{};
    const uint32_t shortLength = length < UINT32_MAX ? static_cast<uint32_t>(length) : UINT32_MAX;
    std::memcpy(header.data(), &shortLength, 4);
    size_t headerSize = 4;
    if (shortLength == UINT32_MAX) { std::memcpy(header.data() + 4, &length, 8); headerSize = 12; }
    auto sendAll = [&](const char* bytes, uint64_t count) {
        uint64_t sent = 0;
        while (sent < count) {
            if (!ready(socketFD, true, ctx)) continue;
            const int result = send(socketFD, bytes + sent, static_cast<int>(std::min<uint64_t>(count - sent, INT_MAX)), 0);
            if (result > 0) { sent += result; continue; }
            const int error = WSAGetLastError();
            if (result == SOCKET_ERROR && error == WSAEWOULDBLOCK) continue;
            disconnect(); throw NetworkException(10061, socketError(error));
        }
    };
    sendAll(reinterpret_cast<const char*>(header.data()), headerSize);
    sendAll(static_cast<const char*>(message), length);
}

uint64_t StreamNetwork::receiveMessageNB(void* message, uint64_t capacity) {
    completedFrame = false;
    if (socketFD == INVALID_SOCKET) throw NetworkException(10056, "no stream client");
    auto readSome = [&](uint8_t* bytes, size_t count) -> int {
        if (ctx->softShutdown || ctx->hardShutdown) { errno = EAGAIN; return -1; }
        const int received = recv(socketFD, reinterpret_cast<char*>(bytes), static_cast<int>(std::min<size_t>(count, INT_MAX)), 0);
        if (received > 0) return received;
        const int error = WSAGetLastError();
        if (received == SOCKET_ERROR && error == WSAEWOULDBLOCK) { errno = EAGAIN; return -1; }
        disconnect();
        if (!received) throw NetworkException(10056, "host disconnected");
        throw NetworkException(10061, socketError(error));
    };
    if (!incomingLengthKnown) {
        size_t required = 4;
        for (;;) {
            if (incomingHeaderUsed < required) {
                const int count = readSome(incomingHeader.data() + incomingHeaderUsed, required - incomingHeaderUsed);
                if (count < 0) return 0;
                incomingHeaderUsed += count;
                continue;
            }
            uint32_t shortLength;
            std::memcpy(&shortLength, incomingHeader.data(), 4);
            if (shortLength == UINT32_MAX && required == 4) { required = 12; continue; }
            uint64_t size = shortLength;
            if (required == 12) std::memcpy(&size, incomingHeader.data() + 4, 8);
            if (size > capacity || size > SIZE_MAX) { disconnect(); throw NetworkException(10055, "TCP frame exceeds receiver buffer"); }
            incomingBody.resize(static_cast<size_t>(size));
            incomingLengthKnown = true; break;
        }
    }
    if (incomingBody.size() > capacity) { disconnect(); throw NetworkException(10055, "TCP frame exceeds receiver buffer"); }
    while (incomingBodyUsed < incomingBody.size()) {
        const int count = readSome(incomingBody.data() + incomingBodyUsed, incomingBody.size() - incomingBodyUsed);
        if (count < 0) return 0;
        incomingBodyUsed += count;
    }
    const size_t count = incomingBody.size();
    if (count) std::memcpy(message, incomingBody.data(), count);
    incomingHeaderUsed = 0; incomingBodyUsed = 0; incomingBody.clear(); incomingLengthKnown = false;
    completedFrame = true; errno = count ? 0 : EAGAIN;
    return count;
}

uint64_t StreamNetwork::receiveMessage(void* message, uint64_t capacity) {
    for (;;) {
        if (ctx->softShutdown || ctx->hardShutdown) throw NetworkException(10056, "stream stopped");
        const uint64_t count = receiveMessageNB(message, capacity);
        if (completedFrame) return count;
        ready(socketFD, false, ctx);
    }
}
}

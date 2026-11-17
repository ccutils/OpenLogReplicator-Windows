/* Header for StreamNetwork class
   Copyright (C) 2018-2026 Adam Leszczynski (aleszczynski@bersler.com)

This file is part of OpenLogReplicator.

OpenLogReplicator is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License as published
by the Free Software Foundation; either version 3, or (at your option)
any later version.

OpenLogReplicator is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
Public License for more details.

You should have received a copy of the GNU General Public License
along with OpenLogReplicator; see the file LICENSE;  If not see
<http://www.gnu.org/licenses/>.  */

#ifndef STREAM_NETWORK_H_
#define STREAM_NETWORK_H_

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <array>
#include <vector>
#else
#include <netinet/in.h>
#endif

#include "Stream.h"

namespace OpenLogReplicator {
    class StreamNetwork final : public Stream {
    protected:
#ifdef _WIN32
        SOCKET socketFD{INVALID_SOCKET};
        SOCKET serverFD{INVALID_SOCKET};
        bool winsockStarted{false};
        std::array<uint8_t, 12> incomingHeader{};
        size_t incomingHeaderUsed{0};
        std::vector<uint8_t> incomingBody;
        size_t incomingBodyUsed{0};
        bool incomingLengthKnown{false};
        bool completedFrame{false};
        void disconnect();
#else
        int socketFD{-1};
        int serverFD{-1};
#endif
        sockaddr_storage address{};
        std::string host;
        std::string port;
        uint8_t readBuffer[READ_NETWORK_BUFFER]{};
        uint64_t readBufferLen{0};
        struct addrinfo* res{nullptr};

    public:
        StreamNetwork(Ctx* newCtx, std::string newUri);
        ~StreamNetwork() override;

        void initialize() override;
        [[nodiscard]] std::string getName() const override;
        void initializeClient() override;
        void initializeServer() override;
        void sendMessage(const void* msg, uint64_t length) override;
        uint64_t receiveMessage(void* msg, uint64_t length) override;
        uint64_t receiveMessageNB(void* msg, uint64_t length) override;
        [[nodiscard]] bool isConnected() override;
    };
}

#endif

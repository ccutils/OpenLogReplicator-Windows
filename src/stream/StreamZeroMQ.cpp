/* Base class for streaming using ZeroMQ
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

#include <unistd.h>
#include <zmq.h>
#include <climits>

#include "../common/Ctx.h"
#include "../common/Thread.h"
#include "../common/exception/NetworkException.h"
#include "../common/exception/RuntimeException.h"
#include "StreamZeroMQ.h"

namespace OpenLogReplicator {
    StreamZeroMQ::StreamZeroMQ(Ctx* newCtx, std::string newUri):
            Stream(newCtx, std::move(newUri)) {}

    StreamZeroMQ::~StreamZeroMQ() {
        if (socket != nullptr) zmq_close(socket);
        if (context != nullptr) zmq_ctx_term(context);
    }

    void StreamZeroMQ::initialize() {
        context = zmq_ctx_new();
        if (context == nullptr)
            throw RuntimeException(10065, "ZeroMQ context creation failed");

        socket = zmq_socket(context, ZMQ_PAIR);
        if (socket == nullptr) {
            throw RuntimeException(10066, "ZeroMQ initializing socket failed, message: " + std::to_string(errno));
        }
        const int linger = 0;
        const int receiveTimeout = 100;
        if (zmq_setsockopt(socket, ZMQ_LINGER, &linger, sizeof(linger)) != 0 ||
            zmq_setsockopt(socket, ZMQ_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout)) != 0)
            throw RuntimeException(10066, "ZeroMQ socket options failed: " + std::to_string(zmq_errno()));
    }

    std::string StreamZeroMQ::getName() const {
        return "ZeroMQ:" + uri;
    }

    void StreamZeroMQ::initializeClient() {
        if (zmq_connect(socket, uri.c_str()) != 0)
            throw NetworkException(10063, "ZeroMQ connect to " + uri + " failed, message: " + std::to_string(errno));
    }

    void StreamZeroMQ::initializeServer() {
        if (zmq_bind(socket, uri.c_str()) != 0)
            throw NetworkException(10064, "ZeroMQ bind to " + uri + " failed, message: " + std::to_string(errno));
    }

    void StreamZeroMQ::sendMessage(const void* msg, uint64_t length) {
        if (length > INT_MAX)
            throw NetworkException(10055, "ZeroMQ frame exceeds supported size");
        while (!ctx->softShutdown) {
            const int64_t ret = zmq_send(socket, msg, length, ZMQ_NOBLOCK);
            if (ret == static_cast<int64_t>(length))
                return;

            if (ret < 0 && zmq_errno() == EAGAIN) {
                if (ctx->writerThread) ctx->writerThread->contextSet(Thread::CONTEXT::SLEEP);
                usleep(ctx->pollIntervalUs);
                if (ctx->writerThread) ctx->writerThread->contextSet(Thread::CONTEXT::CPU);
                continue;
            }

            throw NetworkException(10054, "network send error");
        }
        throw NetworkException(10056, "ZeroMQ stream stopped");
    }

    uint64_t StreamZeroMQ::receiveMessage(void* msg, uint64_t length) {
        while (!ctx->softShutdown && !ctx->hardShutdown) {
            const int64_t ret = zmq_recv(socket, msg, length, 0);
            if (ret >= 0) {
                if (static_cast<uint64_t>(ret) > length) throw NetworkException(10055, "ZeroMQ frame exceeds receiver buffer");
                return ret;
            }
            if (zmq_errno() != EAGAIN) throw NetworkException(10053, "network receive error");
        }
        throw NetworkException(10056, "ZeroMQ stream stopped");
    }

    uint64_t StreamZeroMQ::receiveMessageNB(void* msg, uint64_t length) {
        const int64_t ret = zmq_recv(socket, msg, length, ZMQ_DONTWAIT);
        if (ret < 0) {
            if (zmq_errno() == EAGAIN) {
                errno = EAGAIN;
                return 0;
            }

            throw NetworkException(10053, "network receive error");
        }
        if (static_cast<uint64_t>(ret) > length) throw NetworkException(10055, "ZeroMQ frame exceeds receiver buffer");
        if (ret == 0) errno = EAGAIN;
        return ret;
    }

    bool StreamZeroMQ::isConnected() {
        return true;
    }
}

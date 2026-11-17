// Exercise Windows transport framing with an independent raw Winsock peer.
#include "../../src/common/Ctx.h"
#include "../../src/common/exception/NetworkException.h"
#include "../../src/stream/StreamNetwork.h"
#include "../../src/stream/StreamZeroMQ.h"
#include <iostream>
#include <stdexcept>

using namespace OpenLogReplicator;
static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
static SOCKET connectRaw(int port) {
    SOCKET peer = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(static_cast<u_short>(port));
    require(connect(peer, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "raw connect");
    DWORD timeout = 2000;
    setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    return peer;
}
static uint64_t poll(Stream& stream, char* buffer, size_t size) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < deadline) {
        const auto length = stream.receiveMessageNB(buffer, size);
        if (length) return length;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("receive deadline");
}
static bool acceptPeer(Stream& stream) {
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(std::chrono::steady_clock::now()<deadline) {
        if(stream.isConnected()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}
int main() {
    try {
        Ctx ctx;
        const int port = 32000 + GetCurrentProcessId() % 10000;
        StreamNetwork server(&ctx, "127.0.0.1:" + std::to_string(port));
        server.initialize(); server.initializeServer();
        SOCKET peer = connectRaw(port);
        require(acceptPeer(server), "accept");
        char buffer[32]{};
        const char frame[] = {6,0,0,0,0,10,13,26,static_cast<char>(128),static_cast<char>(255)};
        for (size_t i=0; i<sizeof(frame)-1; ++i) {
            require(send(peer, frame+i, 1, 0)==1, "fragment send");
            require(server.receiveMessageNB(buffer,sizeof(buffer))==0, "partial frame must wait");
        }
        require(send(peer, frame+sizeof(frame)-1,1,0)==1, "final fragment");
        require(poll(server,buffer,sizeof(buffer))==6 && memcmp(buffer,frame+4,6)==0, "fragmented binary frame");
        // Upstream READY serializes as an empty protobuf response.
        const uint32_t zero = 0;
        send(peer,reinterpret_cast<const char*>(&zero),4,0);
        require(server.receiveMessage(buffer,sizeof(buffer))==0,"empty READY frame");
        const uint32_t marker=UINT32_MAX; const uint64_t extended=3;
        send(peer,reinterpret_cast<const char*>(&marker),4,0);
        send(peer,reinterpret_cast<const char*>(&extended),2,0);
        require(server.receiveMessageNB(buffer,sizeof(buffer))==0,"partial extended length");
        send(peer,reinterpret_cast<const char*>(&extended)+2,6,0); send(peer,"abc",3,0);
        require(poll(server,buffer,sizeof(buffer))==3 && memcmp(buffer,"abc",3)==0,"64-bit frame length");
        server.sendMessage("out",3);
        char response[7]{}; int used=0;
        while(used<7) {const int n=recv(peer,response+used,7-used,0); require(n>0,"raw receive"); used+=n;}
        require(response[0]==3 && response[1]==0 && response[2]==0 && response[3]==0 && memcmp(response+4,"out",3)==0,"upstream framing");
        const uint64_t huge=uint64_t{1}<<33;
        send(peer,reinterpret_cast<const char*>(&marker),4,0); send(peer,reinterpret_cast<const char*>(&huge),8,0);
        bool rejected=false;
        try {poll(server,buffer,sizeof(buffer));} catch(NetworkException& ex) {rejected=ex.code==10055;}
        require(rejected,"oversized 64-bit frame rejected before allocation"); closesocket(peer);
        peer=connectRaw(port); require(acceptPeer(server),"reconnect after bad frame");
        closesocket(peer); rejected=false;
        try {poll(server,buffer,sizeof(buffer));} catch(NetworkException& ex) {rejected=ex.code==10056;}
        require(rejected,"peer close detected");
        peer=connectRaw(port); require(acceptPeer(server),"reconnect after close");
        ctx.softShutdown=true; rejected=false;
        try {server.receiveMessage(buffer,sizeof(buffer));} catch(NetworkException&) {rejected=true;}
        require(rejected,"blocked receive cancels on shutdown"); closesocket(peer); ctx.softShutdown=false;
        std::cout<<"PASS TCP: fragmented/binary/empty/extended framing, oversize, close, reconnect, stop\n";
        StreamZeroMQ zmqServer(&ctx,"tcp://127.0.0.1:"+std::to_string(port+1));
        StreamZeroMQ zmqClient(&ctx,"tcp://127.0.0.1:"+std::to_string(port+1));
        zmqServer.initialize(); zmqServer.initializeServer(); zmqClient.initialize(); zmqClient.initializeClient();
        zmqClient.sendMessage(frame+4,6);
        require(poll(zmqServer,buffer,sizeof(buffer))==6 && memcmp(buffer,frame+4,6)==0,"ZeroMQ binary integrity");
        zmqServer.sendMessage(nullptr,0); require(zmqClient.receiveMessage(buffer,sizeof(buffer))==0,"ZeroMQ empty READY");
        zmqClient.sendMessage(frame,sizeof(frame)); rejected=false;
        try {poll(zmqServer,buffer,2);} catch(NetworkException& ex) {rejected=ex.code==10055;}
        require(rejected,"ZeroMQ rejects truncation");
        ctx.hardShutdown=true; rejected=false;
        try {zmqServer.receiveMessage(buffer,sizeof(buffer));} catch(NetworkException&) {rejected=true;}
        require(rejected,"ZeroMQ shutdown receive");
        std::cout<<"PASS ZeroMQ: binary/empty frames, oversize, stop, bounded destructor\n";
        return 0;
    } catch(NetworkException& ex) {std::cerr<<ex.code<<": "<<ex.msg<<'\n';}
      catch(std::exception& ex) {std::cerr<<ex.what()<<'\n';}
    return 1;
}

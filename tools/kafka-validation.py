"""Operate only on the uniquely named topic in an ignored credential file."""
import argparse
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "python"))
from confluent_kafka import Consumer, Producer, TopicPartition, KafkaError
from confluent_kafka.admin import AdminClient, NewTopic


def client_config(access, admin=False):
    return {
        "bootstrap.servers": access["brokers"],
        "security.protocol": access["protocol"],
        "sasl.mechanism": access["mechanism"],
        "sasl.username": access["admin_username" if admin else "username"],
        "sasl.password": access["admin_password" if admin else "password"],
        "client.id": "olrw-isolated-validation",
        "log_level": 0,
        "socket.timeout.ms": 15000,
    }


def read_topic(access):
    topic = access["topic"]
    config = client_config(access)
    config.update({"group.id": topic + "-verify", "enable.auto.commit": False,
                   "enable.auto.offset.store": False, "allow.auto.create.topics": False,
                   "enable.partition.eof": True})
    consumer = Consumer(config)
    records = []
    try:
        partition = TopicPartition(topic, 0)
        low, high = consumer.get_watermark_offsets(partition, timeout=20)
        consumer.assign([TopicPartition(topic, 0, low)])
        deadline = time.monotonic() + 45
        while high > low and time.monotonic() < deadline:
            message = consumer.poll(1)
            if message is None:
                continue
            if message.error():
                if message.error().code() == KafkaError._PARTITION_EOF:
                    break
                raise RuntimeError(str(message.error()))
            records.append({"offset": message.offset(), "value": message.value()})
            if message.offset() >= high - 1:
                break
        if len(records) != high - low:
            raise RuntimeError(f"Incomplete topic read: {len(records)} records, offsets {low}..{high}")
        return records
    finally:
        consumer.close()  # assign(), no group join and no offset commit.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["create", "consume", "verify"])
    args = parser.parse_args()
    access = json.loads((ROOT / "config/kafka-access.local.json").read_text(encoding="utf-8-sig"))
    topic = access["topic"]
    if not re.fullmatch(r"olrw_win2012_cdc_20261116_[0-9a-f]{8}", topic):
        raise RuntimeError("Refusing a topic outside this validation's unique namespace")
    output = ROOT / "test-results/kafka"
    output.mkdir(parents=True, exist_ok=True)
    try:
        if args.mode == "create":
            admin = AdminClient(client_config(access, admin=True))
            specification = NewTopic(topic, num_partitions=1, replication_factor=1,
                                     config={"retention.ms": "86400000", "min.insync.replicas": "1"})
            admin.create_topics([specification], operation_timeout=20, request_timeout=30)[topic].result(35)
            print(f"Created only test topic: {topic}")
            metadata = Producer(client_config(access)).list_topics(topic=topic, timeout=20)
            error = metadata.topics[topic].error
            if error:
                raise RuntimeError(str(error))
            print("PASS: app_user SCRAM authentication and test-topic metadata access")
            summary = {"topic": topic, "brokers": access["brokers"], "partitions": 1,
                       "protocol": access["protocol"], "mechanism": access["mechanism"],
                       "producer_user": access["username"], "row_base": access["row_base"]}
            (output / "topic.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
            return
        records = read_topic(access)
        (output / "consumed.jsonl").write_bytes(b"\n".join(record["value"] for record in records) + (b"\n" if records else b""))
        print(f"Read only {topic}: {len(records)} messages; no consumer offsets committed")
        if args.mode == "consume":
            return
        messages = [json.loads(record["value"]) for record in records]
        payloads = [payload for message in messages for payload in message["payload"]]
        dml = [p for p in payloads if p["op"] in ("c", "u", "d")]
        base = access["row_base"]
        assert len(dml) == 4, f"Expected four DML events, found {len(dml)}"
        assert [p["op"] for p in dml] == ["c", "u", "c", "d"]
        assert all(p["schema"]["owner"] == "OLRW_20261116_7A32" and p["schema"]["table"] == "CDC_TEST" for p in dml)
        assert dml[0]["after"] == {"ID": base + 1, "VALUE": "kafka-first", "OPTIONAL_VALUE": None}
        assert dml[1]["before"] == dml[0]["after"]
        assert dml[1]["after"] == {"ID": base + 1, "VALUE": "\u4e2d\u6587", "OPTIONAL_VALUE": "kafka-updated"}
        assert dml[2]["after"] == {"ID": base + 2, "VALUE": "kafka-retained", "OPTIONAL_VALUE": None}
        assert dml[3]["before"] == dml[1]["after"]
        assert not any(p.get(side, {}).get("ID") == base + 3 for p in dml for side in ("before", "after"))
        assert sum(p["op"] == "begin" for p in payloads) == 4
        assert sum(p["op"] == "commit" for p in payloads) == 4
        identities = [(m["c_scn"], m["c_idx"]) for m in messages]
        assert len(set(identities)) == len(identities)
        summary = {"passed": True, "topic": topic, "message_count": len(records), "dml_count": len(dml),
                   "ops": [p["op"] for p in dml], "first_offset": records[0]["offset"],
                   "last_offset": records[-1]["offset"], "last_c_scn": messages[-1]["c_scn"],
                   "last_c_idx": messages[-1]["c_idx"], "row_base": base,
                   "checks": ["Oracle DML order", "before/after", "exact Unicode", "NULL", "rollback absent",
                              "transaction boundaries", "unique checkpoint identities"]}
        (output / "verification.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print("PASS: INSERT/UPDATE/DELETE, before/after, Chinese, NULL, rollback, transaction boundaries, unique identities")
    except Exception as error:
        detail = str(error)
        for key in ("password", "admin_password"):
            detail = detail.replace(access[key], "[REDACTED]")
        raise RuntimeError(detail) from None


if __name__ == "__main__":
    main()

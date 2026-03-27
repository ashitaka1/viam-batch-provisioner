#!/usr/bin/env python3
"""
Fetch cloud credentials for a Viam machine part.

Uses the provisioning key (not deployed to targets) to retrieve the
cloud credentials (id + secret) that go into /etc/viam.json.

Usage:
    python3 fetch-credentials.py --part-id <PART_ID> --output <PATH>

Requires: pip install viam-sdk
Auth: reads VIAM_API_KEY_ID and VIAM_API_KEY from environment.
"""

import argparse
import asyncio
import json
import os
import sys


async def fetch(part_id: str, output: str):
    try:
        from viam.app.viam_client import ViamClient
        from viam.rpc.dial import Credentials, DialOptions
    except ImportError:
        print("ERROR: viam-sdk not installed. Run: pip install viam-sdk", file=sys.stderr)
        sys.exit(1)

    key_id = os.environ.get("VIAM_API_KEY_ID")
    key = os.environ.get("VIAM_API_KEY")

    if not key_id or not key:
        print("ERROR: VIAM_API_KEY_ID and VIAM_API_KEY must be set", file=sys.stderr)
        sys.exit(1)

    dial_options = DialOptions(
        credentials=Credentials(type="api-key", payload=key),
        auth_entity=key_id,
    )
    client = await ViamClient.create_from_dial_options(dial_options)

    try:
        app = client.app_client
        part = await app.get_robot_part(robot_part_id=part_id)

        viam_json = {
            "cloud": {
                "app_address": "https://app.viam.com:443",
                "id": part.id,
                "secret": part.secret,
            }
        }

        with open(output, "w") as f:
            json.dump(viam_json, f)

        print(json.dumps(viam_json))
    finally:
        result = client.close()
        if result is not None:
            await result


def main():
    parser = argparse.ArgumentParser(description="Fetch Viam machine cloud credentials")
    parser.add_argument("--part-id", required=True, help="Machine part ID")
    parser.add_argument("--output", required=True, help="Output path for viam.json")
    args = parser.parse_args()

    asyncio.run(fetch(args.part_id, args.output))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Resolve Viam org and location IDs to human-readable names.

Usage:
    python3 resolve-labels.py --org-id <ID> --location-id <ID>

Prints:
    ORG_NAME=<name>
    LOCATION_NAME=<name>

Auth: reads VIAM_API_KEY_ID and VIAM_API_KEY from environment.
"""

import argparse
import asyncio
import os
import sys


async def resolve(org_id: str, location_id: str):
    from viam.app.viam_client import ViamClient
    from viam.rpc.dial import Credentials, DialOptions

    key_id = os.environ.get("VIAM_API_KEY_ID")
    key = os.environ.get("VIAM_API_KEY")
    if not key_id or not key:
        print("ERROR: VIAM_API_KEY_ID and VIAM_API_KEY must be set", file=sys.stderr)
        sys.exit(1)

    client = await ViamClient.create_from_dial_options(DialOptions(
        credentials=Credentials(type="api-key", payload=key),
        auth_entity=key_id,
    ))

    try:
        app = client.app_client
        try:
            org = await app.get_organization(org_id=org_id)
            print(f"ORG_NAME={org.name}")
        except Exception as e:
            print(f"ORG_NAME=<unresolved: {e}>")

        try:
            loc = await app.get_location(location_id=location_id)
            print(f"LOCATION_NAME={loc.name}")
        except Exception as e:
            print(f"LOCATION_NAME=<unresolved: {e}>")
    finally:
        result = client.close()
        if result is not None:
            await result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--org-id", required=True)
    parser.add_argument("--location-id", required=True)
    args = parser.parse_args()
    asyncio.run(resolve(args.org_id, args.location_id))


if __name__ == "__main__":
    main()

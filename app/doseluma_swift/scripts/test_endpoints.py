#!/usr/bin/env python3
"""
Test script for DoseLuma Server WebSocket endpoints.
Usage: python3 test_endpoints.py [--host localhost --port 8080]

Auth Architecture: ALL login goes through Auth0.
- POST /api/auth/auth0 → Auth0 OIDC+PKCE → Backend issues JWT bound to Auth0 identity
- POST /api/auth/redeem → QR code → Backend issues JWT bound to patient's Auth0 identity + device
- POST /api/mobile/sync → Auto-links device on first sync, renews JWT with device_id binding
"""

import argparse
import asyncio
import base64
import json
import sys
import time
import uuid

try:
    import websockets
except ImportError:
    print("ERROR: websockets package not installed. Run: pip3 install websockets")
    sys.exit(1)


class DoseLumaTestClient:
    def __init__(self, host="localhost", port=8080):
        self.host = host
        self.port = port
        self.ws = None
        self.pending = {}

    async def connect(self):
        url = f"ws://{self.host}:{self.port}/"
        print(f"[CONNECT] Connecting to {url}")
        self.ws = await websockets.connect(url)
        print(f"[CONNECT] Connected successfully")
        return self

    async def close(self):
        if self.ws:
            await self.ws.close()
            print(f"[CLOSE] Disconnected")

    async def _listen_for_responses(self):
        """Background task to receive responses and match them to pending requests."""
        try:
            async for message in self.ws:
                data = json.loads(message)
                req_id = data.get("id")
                if req_id and req_id in self.pending:
                    self.pending[req_id] = data
        except websockets.exceptions.ConnectionClosed:
            pass

    async def send_request(self, method, path, body=None, headers=None, expect_status=200):
        """Send a request over WebSocket and wait for the response."""
        req_id = str(uuid.uuid4())
        
        headers = headers or {}
        body_b64 = ""
        if body is not None:
            body_b64 = base64.b64encode(json.dumps(body).encode()).decode()

        frame = {
            "id": req_id,
            "method": method,
            "path": path,
            "query": "",
            "headers": headers,
            "body": body_b64
        }

        self.pending[req_id] = None
        await self.ws.send(json.dumps(frame))

        # Poll for response with timeout
        timeout = 15  # Auth0 can take up to 10s
        start = time.time()
        while time.time() - start < timeout:
            if self.pending.get(req_id) is not None:
                break
            await asyncio.sleep(0.1)

        response = self.pending.pop(req_id)
        if response is None:
            raise TimeoutError(f"Request {method} {path} timed out after {timeout}s")

        status = response.get("status")
        resp_body = response.get("body", {})
        
        print(f"[RESPONSE] {method} {path} -> {status}")
        if isinstance(resp_body, dict):
            print(f"  {json.dumps(resp_body, indent=2)}")
        else:
            print(f"  {resp_body}")

        if expect_status and status != expect_status:
            error_msg = resp_body.get("error", "Unknown error") if isinstance(resp_body, dict) else str(resp_body)
            raise AssertionError(f"Expected status {expect_status} but got {status}: {error_msg}")

        return resp_body


async def test_health(client):
    """Test 1: Health check"""
    print("\n" + "="*60)
    print("TEST 1: Health Check (GET /api/health)")
    print("="*60)
    resp = await client.send_request("GET", "/api/health")
    assert resp.get("status") == "ok", f"Expected status 'ok', got {resp}"
    print("✓ Health check passed")
    return resp


async def test_auth0_invalid_code(client):
    """Test 2: Auth0 flow with invalid code (expect graceful Auth0 error)"""
    print("\n" + "="*60)
    print("TEST 2: Auth0 Flow with Invalid Code (expect graceful error)")
    print("="*60)
    
    try:
        resp = await client.send_request(
            "POST", "/api/auth/auth0",
            body={"code": "fake-code-123", "code_verifier": "fake-verifier-456"},
            expect_status=400
        )
        if "error" in resp:
            print(f"✓ Auth0 correctly rejected invalid code: {resp.get('error', resp)}")
        else:
            print(f"✗ Unexpected: {resp}")
            raise AssertionError(f"Auth0 should have returned error, got: {resp}")
    except AssertionError as e:
        print(f"✗ Unexpected: {e}")
        raise


async def test_removed_endpoints(client):
    """Test 3: Verify name-based register/login are removed (should 404)"""
    print("\n" + "="*60)
    print("TEST 3: Removed Endpoints Return 404")
    print("="*60)
    
    try:
        await client.send_request(
            "POST", "/api/auth/register",
            body={"display_name": "Should Not Work", "username": "test", "role": "patient"},
            expect_status=404
        )
        print("✓ /api/auth/register correctly returns 404")
    except AssertionError as e:
        print(f"✗ Register endpoint should be 404: {e}")
        raise

    try:
        await client.send_request(
            "POST", "/api/auth/login",
            body={"username": "test", "password": "test"},
            expect_status=404
        )
        print("✓ /api/auth/login correctly returns 404")
    except AssertionError as e:
        print(f"✗ Login endpoint should be 404: {e}")
        raise


async def test_mobile_sync_invalid_jwt(client):
    """Test 4: Mobile sync with invalid JWT (expect 401)"""
    print("\n" + "="*60)
    print("TEST 4: Mobile Sync with Invalid JWT (expect 401)")
    print("="*60)
    
    try:
        await client.send_request(
            "POST", "/api/mobile/sync",
            body={
                "device_id": "some-device",
                "current_screen": "Schedule",
                "snapshot": {"time_windows": [], "medications": [], "adherence_records": [], "vitals": [], "ui": {"currentScreen": "Schedule", "activeMedicationCount": 0, "adherenceRecordCount": 0, "timeWindowCount": 0}}
            },
            headers={"x-user-token": "not-a-valid-jwt"},
            expect_status=401
        )
        print("✓ Invalid JWT correctly rejected with 401")
    except AssertionError as e:
        print(f"✗ Invalid JWT test failed: {e}")
        raise


async def test_redeem_invalid_token(client):
    """Test 5: QR redeem with invalid token (expect 404)"""
    print("\n" + "="*60)
    print("TEST 5: QR Redeem with Invalid Token (expect 404)")
    print("="*60)
    
    try:
        await client.send_request(
            "POST", "/api/auth/redeem",
            body={"pairing_token": "fake-token", "device_id": "test-device"},
            expect_status=404
        )
        print("✓ Invalid pairing token correctly rejected with 404")
    except AssertionError as e:
        print(f"✗ Invalid redeem test failed: {e}")
        raise


async def test_jwt_structure(client, jwt_token):
    """Verify the JWT has proper claims"""
    parts = jwt_token.split(".")
    assert len(parts) == 3, f"JWT should have 3 parts, got {len(parts)}"
    
    # Decode payload
    import base64
    payload_b64 = parts[1]
    # Add padding
    payload_b64 += "=" * (4 - len(payload_b64) % 4)
    payload = json.loads(base64.b64decode(payload_b64))
    
    print(f"  JWT claims: user_id={payload.get('user_id', '?')}, auth0_sub={payload.get('auth0_sub', '?')}, device_id={payload.get('device_id', 'null')}")
    assert "user_id" in payload, "JWT missing user_id"
    assert "auth0_sub" in payload, "JWT missing auth0_sub"
    assert "exp" in payload, "JWT missing exp"
    assert "iat" in payload, "JWT missing iat"
    assert "jti" in payload, "JWT missing jti"
    return payload


async def main():
    parser = argparse.ArgumentParser(description="Test DoseLuma Server endpoints")
    parser.add_argument("--host", default="localhost", help="Server host (default: localhost)")
    parser.add_argument("--port", type=int, default=8080, help="Server port (default: 8080)")
    args = parser.parse_args()

    client = DoseLumaTestClient(host=args.host, port=args.port)

    try:
        await client.connect()

        # Start background listener
        asyncio.create_task(client._listen_for_responses())
        await asyncio.sleep(0.2)  # Let listener start

        results = {"passed": 0, "failed": 0, "errors": []}

        print("\n" + "#"*60)
        print("# DoseLuma Server Auth Architecture Test Suite")
        print("# ALL login through Auth0 → Backend JWT → Device binding")
        print("#"*60)

        # Test 1: Health
        try:
            await test_health(client)
            results["passed"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append(f"Health: {e}")
            print(f"✗ Health check failed: {e}")

        # Test 2: Auth0 invalid code
        try:
            await test_auth0_invalid_code(client)
            results["passed"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append(f"Auth0: {e}")
            print(f"✗ Auth0 test failed: {e}")

        # Test 3: Removed endpoints
        try:
            await test_removed_endpoints(client)
            results["passed"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append(f"Removed endpoints: {e}")
            print(f"✗ Removed endpoints test failed: {e}")

        # Test 4: Invalid JWT
        try:
            await test_mobile_sync_invalid_jwt(client)
            results["passed"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append(f"Invalid JWT: {e}")
            print(f"✗ Invalid JWT test failed: {e}")

        # Test 5: Invalid QR redeem
        try:
            await test_redeem_invalid_token(client)
            results["passed"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append(f"QR redeem: {e}")
            print(f"✗ QR redeem test failed: {e}")

        # Summary
        print("\n" + "="*60)
        print("TEST SUMMARY")
        print("="*60)
        print(f"  Passed: {results['passed']}")
        print(f"  Failed: {results['failed']}")
        if results["errors"]:
            print(f"\n  Errors:")
            for err in results["errors"]:
                print(f"    - {err}")
        print("="*60)

        if results["failed"] > 0:
            sys.exit(1)
        else:
            print("\n✓ All tests passed!")

    except ConnectionRefusedError:
        print(f"\n✗ Could not connect to {args.host}:{args.port}")
        print("  Make sure the DoseLuma Server is running.")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())

#!/usr/bin/env bash
# verify_origin_private.sh — IA-128
#
# Checks, from outside the account and with no credentials, that the S3 origin
# refuses direct anonymous access while CloudFront serves the same object.
#
# It reports THREE outcomes, not two. The third exists because on a bucket with
# Block Public Access enabled, S3 answers 403 to an anonymous request for an
# object that DOES NOT EXIST, exactly as it does for one that exists and is
# denied. A bare 403 therefore proves nothing on its own: a typo in the bucket
# name, the region or the key produces the same code as a working policy.
#
# This is the INCONCLUSIVE lesson from IA-75, in a different service.
#
# Usage:
#   ./verify_origin_private.sh <bucket> <region> <distribution-domain> [key]
# Example:
#   ./verify_origin_private.sh my-bucket us-east-1 d111111abcdef8.cloudfront.net index.html

set -u

BUCKET="${1:?bucket name required}"
REGION="${2:?region required}"
DIST="${3:?cloudfront domain required}"
KEY="${4:-index.html}"
ABSENT="__this_key_does_not_exist_$(date +%s)__"

ORIGIN="https://${BUCKET}.s3.${REGION}.amazonaws.com"
CDN="https://${DIST}"

if [ -n "${AWS_ACCESS_KEY_ID:-}${AWS_PROFILE:-}${AWS_SESSION_TOKEN:-}" ]; then
  echo "REFUSED: AWS credentials are present in this environment."
  echo "         This check must run as an outsider would. Unset them and re-run."
  exit 2
fi

code() { curl -s -o "${2:-/dev/null}" -w "%{http_code}" --max-time 20 "$1"; }

echo "origin : $ORIGIN"
echo "cdn    : $CDN"
echo "key    : $KEY"
echo

tmp_cdn="$(mktemp)"; trap 'rm -f "$tmp_cdn"' EXIT

c_origin=$(code "$ORIGIN/$KEY")
c_absent=$(code "$ORIGIN/$ABSENT")
c_cdn=$(code   "$CDN/$KEY" "$tmp_cdn")
c_cdn_absent=$(code "$CDN/$ABSENT")

printf '%-46s %s\n' "1. origin, real key          (want 403)" "$c_origin"
printf '%-46s %s\n' "2. origin, absent key        (want 403)" "$c_absent"
printf '%-46s %s\n' "3. cdn,    real key          (want 200)" "$c_cdn"
printf '%-46s %s\n' "4. cdn,    absent key   (want 403 or 404)" "$c_cdn_absent"
echo

fail=0

if [ "$c_cdn" != "200" ]; then
  echo "FAIL  the CDN does not serve the object. Nothing below is meaningful."
  exit 1
fi
echo "PASS  the CDN serves the object."
echo "      sha256 as served: $(sha256sum "$tmp_cdn" | cut -d' ' -f1)"
echo "      compare that against the file you uploaded. Bytes, not appearance."
echo

if [ "$c_origin" != "403" ]; then
  echo "FAIL  the origin answered $c_origin, not 403. The bucket is reachable directly."
  fail=1
else
  if [ "$c_absent" = "403" ]; then
    echo "INCONCLUSIVE  the origin returns 403 for the real key AND for a key that"
    echo "              cannot exist. That is the expected S3 behaviour with Block"
    echo "              Public Access on, and it means this reading alone does not"
    echo "              distinguish a working policy from a wrong bucket or region."
    echo
    echo "              Resolve it with the red check below. Do NOT record a pass"
    echo "              until you have seen this probe return 200."
  else
    echo "PASS  the origin refuses the real key (403) and answers $c_absent for an"
    echo "      absent one, so the 403 is a denial rather than a lookup failure."
  fi
fi

cat <<'NOTE'

--- THE RED CHECK, and it is not optional -------------------------------------
A check that cannot fail proves nothing.

  1. In the console, upload a throwaway object, e.g. redcheck.txt.
  2. Grant it public read, deliberately.
  3. Run:  ./verify_origin_private.sh <bucket> <region> <dist> redcheck.txt
     Probe 1 MUST come back 200. If it still says 403, the probe is wrong,
     not the policy, and every other reading in this file is worthless.
  4. Remove the grant. Re-run. Probe 1 MUST return to 403.
  5. Delete redcheck.txt.

Record all three readings on IA-128. Without the middle one you have a number,
not evidence.
-------------------------------------------------------------------------------
NOTE

exit $fail

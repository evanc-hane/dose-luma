# speaches (local offline STT/TTS) with two fixes for Chinese support:
#
# 1. espeak-ng isn't installed in the upstream "latest-cpu" image at all, so
#    Kokoro's phonemizer backend has no Mandarin ("cmn") data to fall back on.
# 2. speaches.text_utils.strip_emojis() has an overbroad Unicode range
#    (\U000024c2-\U0001f251) that accidentally strips the entire CJK block —
#    every Chinese character — before synthesis, for both Kokoro and Piper.
#    See https://github.com/speaches-ai/speaches (upstream bug, not ours).
FROM ghcr.io/speaches-ai/speaches:latest-cpu

USER root
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends espeak-ng \
    && rm -rf /var/lib/apt/lists/*

RUN python3 - <<'EOF'
path = "/home/ubuntu/speaches/src/speaches/text_utils.py"
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
target = '        "\\U000024c2-\\U0001f251"\n'
assert target in lines, "strip_emojis regex line not found — upstream file changed, re-check the patch"
lines.remove(target)
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
EOF

USER ubuntu

#!/bin/zsh
# ดับเบิลคลิกเพื่อใส่กุญแจ GitHub ร่วม — จะมีหน้าต่างให้วางกุญแจ แล้วกด OK
cd "$(dirname "$0")"
NOVEL_TOKEN_DIALOG=1 ./novel token
echo ""
read -k1 "?กดปุ่มใดก็ได้เพื่อปิดหน้าต่างนี้"

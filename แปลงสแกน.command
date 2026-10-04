#!/bin/zsh
# ดับเบิลคลิกไฟล์นี้เพื่อแปลงทุก PDF ในโฟลเดอร์ "สแกน" เป็นหนังสือบนชั้น แล้วส่งขึ้น GitHub
# (เหมือนพิมพ์  ./novel scan  ใน Terminal)
cd "$(dirname "$0")"
mkdir -p "สแกน"
if [[ -z "$(ls สแกน/*.(pdf|PDF)(N) 2>/dev/null)" ]]; then
  echo "ยังไม่มีไฟล์ในโฟลเดอร์ \"สแกน\" — ใส่ไฟล์ PDF ลงไปแล้วดับเบิลคลิก แปลงสแกน.command อีกครั้ง"
  open "สแกน"
else
  ./novel scan
fi
read -k1 "?กดปุ่มใดก็ได้เพื่อปิด"

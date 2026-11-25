原始文件取自最初导入的 xmz28/CarWithin v1.0.3 提交 dfb6c25a239eb52e7fab39c1299cb4120a0780f0。
App/Zeeho62Legacy.swift 将原 6.2 寸输出、连接协商和协议编解码封装到独立命名空间。
ZeehoOutput 原输出代码不修改，协商代码仅增加用户授权的自动 IP 发现入口、复用探测连接和成功地址记忆。
SPS/编码尺寸固定为原 1024×480，输出 25 FPS、2.5 Mbit/s，原有控制命令处理及媒体协商回应保留。
原始 Socket 和 RSA 身份实现与当前共用文件逐字节一致，Data 字节读写扩展也保持原样。
manifest.json 记录原文件 Git blob/SHA-256 及嵌入代码块哈希。Tools/verify_legacy62.py 可检查恢复结果。

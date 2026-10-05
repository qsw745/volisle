# 安全问题报告 · Security

**请不要在公开 issue 里提交安全问题。**

盘屿包含一个以 root 运行的后台组件和一个文件系统扩展，会读写用户的磁盘。如果你发现可能导致数据损坏、越权访问或绕过安全检查的问题，请私下报告：

- 在本仓库的 **Security → Report a vulnerability** 提交私密报告（GitHub 私密漏洞报告）。

请尽量写明：盘屿版本、macOS 版本、复现步骤、影响范围。收到后会尽快确认，修复发布前不会公开细节。

---

**Please don't report security issues in public issues.**

Volisle includes a background component that runs as root and a file system extension that reads and writes users' disks. If you find something that could corrupt data, grant access it shouldn't, or bypass a safety check, report it privately:

- Use **Security → Report a vulnerability** in this repository (GitHub private vulnerability reporting).

Please include the Volisle and macOS versions, steps to reproduce, and the impact. Details stay private until a fix is released.

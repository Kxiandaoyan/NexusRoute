# NexusRoute 升级指南

## 功能更新

### 1. 节点层级绑定
- 添加节点时需要选择跳数层级（第一跳/第二跳/第三跳）
- 每个节点只能在指定的层级使用，防止混用暴露
- 用户配置路由时，每个跳数只显示对应层级的节点

### 2. 数据库变更
- `nodes` 表新增 `hop_level` 字段（1=第一跳, 2=第二跳, 3=第三跳）
- 自动为现有节点设置为第一跳

## 升级步骤

### 一键升级（推荐）

直接在服务器上执行以下命令：

```bash
# 下载升级脚本
curl -O https://raw.githubusercontent.com/Kxiandaoyan/NexusRoute/main/update.sh

# 添加执行权限
chmod +x update.sh

# 执行升级
sudo ./update.sh
```

升级脚本会自动：
1. 从 GitHub 下载最新代码
2. 备份现有文件和数据库
3. 停止服务
4. 更新文件
5. 执行数据库迁移
6. 重启服务
7. 验证服务状态
8. 如果失败自动回滚

### 手动升级（不推荐）

如果自动升级失败，可以手动操作：

1. 备份现有文件：
```bash
sudo mkdir -p /opt/nexusroute/backup
sudo cp /opt/nexusroute/server.js /opt/nexusroute/backup/
sudo cp -r /opt/nexusroute/public /opt/nexusroute/backup/
sudo cp /opt/nexusroute/db.sqlite /opt/nexusroute/backup/
```

2. 下载最新代码：
```bash
cd /tmp
git clone https://github.com/Kxiandaoyan/NexusRoute.git
cd NexusRoute
```

3. 停止服务：
```bash
sudo systemctl stop nexusroute
```

4. 更新文件：
```bash
sudo cp server.js /opt/nexusroute/
sudo cp public/admin.html /opt/nexusroute/public/
sudo cp public/index.html /opt/nexusroute/public/
```

5. 数据库迁移：
```bash
sudo sqlite3 /opt/nexusroute/db.sqlite <<EOF
ALTER TABLE nodes ADD COLUMN hop_level INTEGER DEFAULT 1;
CREATE INDEX IF NOT EXISTS idx_nodes_hop_level ON nodes(hop_level, enabled);
UPDATE nodes SET hop_level = 1 WHERE hop_level IS NULL;
EOF
```

6. 启动服务：
```bash
sudo systemctl start nexusroute
sudo systemctl status nexusroute
```

## 升级后操作

1. 访问管理后台：http://192.168.100.1/admin

2. 检查现有节点：
   - 所有现有节点默认设置为"第一跳"
   - 如需调整，请删除后重新添加并选择正确的层级

3. 添加新节点时：
   - 必须选择"跳数层级"（第一跳/第二跳/第三跳）
   - 建议按实际使用场景规划节点层级

4. 用户配置路由：
   - 第一跳下拉框只显示第一跳节点
   - 第二跳下拉框只显示第二跳节点
   - 第三跳下拉框只显示第三跳节点

## 回滚方法

如果升级后出现问题，升级脚本会自动回滚。如需手动回滚：

```bash
sudo systemctl stop nexusroute
sudo cp /opt/nexusroute/backup_YYYYMMDD_HHMMSS/server.js /opt/nexusroute/
sudo cp -r /opt/nexusroute/backup_YYYYMMDD_HHMMSS/public/* /opt/nexusroute/public/
sudo cp /opt/nexusroute/backup_YYYYMMDD_HHMMSS/db.sqlite /opt/nexusroute/
sudo systemctl start nexusroute
```

## 验证升级

1. 检查服务状态：
```bash
sudo systemctl status nexusroute
```

2. 查看日志：
```bash
sudo journalctl -u nexusroute -n 50
```

3. 测试管理后台：
   - 访问 http://192.168.100.1/admin
   - 登录后查看节点列表，应该显示"层级"列

4. 测试用户前台：
   - 访问 http://192.168.100.1/
   - 查看节点选择，应该按层级分类

## 常见问题

### Q: 升级脚本下载失败怎么办？
A: 检查服务器网络连接，或者使用代理：
```bash
export https_proxy=http://your-proxy:port
curl -O https://raw.githubusercontent.com/Kxiandaoyan/NexusRoute/main/update.sh
```

### Q: 数据库迁移失败怎么办？
A: 升级脚本会自动回滚。如需手动修复，检查数据库文件权限：
```bash
sudo chown root:root /opt/nexusroute/db.sqlite
sudo chmod 644 /opt/nexusroute/db.sqlite
```

### Q: 升级后节点列表为空？
A: 检查数据库迁移是否成功：
```bash
sudo sqlite3 /opt/nexusroute/db.sqlite "PRAGMA table_info(nodes);" | grep hop_level
```
如果没有输出，说明迁移失败，需要手动执行迁移 SQL。

### Q: 如何查看备份位置？
A: 备份目录在 `/opt/nexusroute/backup_YYYYMMDD_HHMMSS/`，升级完成后会显示具体路径。

## 注意事项

- 升级脚本会自动创建备份
- 数据库迁移是安全的，不会丢失数据
- 如果服务启动失败，脚本会自动回滚
- 建议在低峰期进行升级操作
- 升级前确保服务器有足够的磁盘空间（至少 100MB）
- 升级过程中服务会短暂中断（约 10-30 秒）

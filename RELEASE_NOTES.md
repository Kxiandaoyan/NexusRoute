# NexusRoute v2.1 Release Notes

## 🎉 新功能

### 节点层级绑定
- 添加节点时必须选择跳数层级（第一跳/第二跳/第三跳）
- 每个节点只能在指定层级使用，防止混用导致的安全风险
- 用户前台按层级过滤节点，避免配置错误

**使用场景**：
```
第一跳：入口节点（高速、稳定）
第二跳：中转节点（地理位置优化）
第三跳：出口节点（目标地区）
```

### 一键升级脚本
- 支持从 GitHub 自动下载最新版本
- 自动备份现有配置和数据库
- 失败时自动回滚，确保服务稳定
- 自动执行数据库迁移

**使用方法**：
```bash
curl -O https://raw.githubusercontent.com/Kxiandaoyan/NexusRoute/main/update.sh
chmod +x update.sh
sudo ./update.sh
```

## 🐛 Bug 修复

### 修复 /admin 路由无法访问
- 添加了 `/admin` 到 `admin.html` 的路由映射
- 现在可以直接访问 `http://192.168.100.1/admin`

## 🔧 改进

### 数据库优化
- 新增 `hop_level` 字段到 `nodes` 表
- 添加索引提升查询性能
- 提供数据库迁移脚本

### 文档完善
- 新增 `UPGRADE.md` 升级指南
- 更新 `README.md` 添加升级说明
- 添加版本更新日志

## 📦 升级说明

### 从 v2.0 升级到 v2.1

**自动升级（推荐）**：
```bash
curl -O https://raw.githubusercontent.com/Kxiandaoyan/NexusRoute/main/update.sh
chmod +x update.sh
sudo ./update.sh
```

**手动升级**：
参考 [UPGRADE.md](UPGRADE.md) 文档

### 升级后注意事项

1. **现有节点默认为第一跳**
   - 所有现有节点会自动设置为"第一跳"
   - 如需调整，请删除后重新添加并选择正确层级

2. **添加新节点时必须选择层级**
   - 管理后台添加节点时会看到"跳数层级"选择器
   - 必须选择第一跳/第二跳/第三跳

3. **用户前台按层级显示节点**
   - 第一跳下拉框只显示第一跳节点
   - 第二跳下拉框只显示第二跳节点
   - 第三跳下拉框只显示第三跳节点

## 🔒 安全性增强

### 节点隔离
通过层级绑定，确保：
- 入口节点不会被用作出口
- 出口节点不会被用作入口
- 降低节点关联性，提高匿名性

### 配置验证
- 前端和后端双重验证节点层级
- 防止错误配置导致的安全问题

## 📊 兼容性

- ✅ 向后兼容 v2.0
- ✅ 自动数据库迁移
- ✅ 保留所有现有配置
- ✅ 无需重新配置用户设备

## 🙏 致谢

感谢所有用户的反馈和建议！

## 📞 支持

- 问题反馈：https://github.com/Kxiandaoyan/NexusRoute/issues
- 文档：https://github.com/Kxiandaoyan/NexusRoute/blob/main/README.md
- 升级指南：https://github.com/Kxiandaoyan/NexusRoute/blob/main/UPGRADE.md

---

**发布日期**：2026-04-10  
**版本号**：v2.1  
**Git Tag**：v2.1.0

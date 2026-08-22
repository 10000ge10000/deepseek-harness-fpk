#!/usr/bin/env python3
"""生成 fnOS 第三方应用源索引与发布落地页。

由 workflow 的 build job 在发布 Release 后调用，产出 public/ 下三个文件：
appstore.json（应用源格式）、manifests.json（裸数组）、index.html（下载页）。

用法：
  python3 scripts/ci/generate-appstore.py \
      --version 0.1.2 --tag v0.1.2 \
      --x86-fk deepseek-harness_0.1.2_x86.fpk \
      --arm-fpk deepseek-harness_0.1.2_arm.fpk \
      --out-dir public

仓库 slug 默认取 GITHUB_REPOSITORY 环境变量（fork 后链接自动正确）。
"""

import argparse
import datetime
import hashlib
import json
import os


def package_fingerprint(path: str) -> dict:
    """计算安装包的 sha256 与字节数（FnDepot 强制校验，必须与真实文件一致）。"""
    h = hashlib.sha256()
    size = 0
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            size += len(chunk)
    return {'sha256': h.hexdigest(), 'size': size}


def build_app_entry(repo: str, ver: str, tag_name: str, fpk_file: str, platform: str) -> dict:
    arch_label = 'x86_64' if platform == 'x86' else 'ARM64 / aarch64'
    return {
        'name': 'DeepSeekHarness',
        'title': f'DeepSeek Harness (一万AI分享定制版 - {platform.upper()})',
        'version': ver,
        'platform': platform,
        'author': '一万AI分享',
        'description': f'DeepSeek 官方 AI 开发助手与桌面工作台 ({arch_label} 架构)。预制一万AI分享提供商，模型和 API 均可编辑，文件管理实时互通。',
        'icon': f'https://raw.githubusercontent.com/{repo}/main/apps/deepseek-harness/fnos/ICON_256.PNG',
        'download_url': f'https://github.com/{repo}/releases/download/{tag_name}/{fpk_file}',
        'changelog': '一键开箱即用，支持局域网非安全上下文 Polyfill，飞牛文件管理双向打通。'
    }


def build_index_html(ver: str, app_x86: dict, app_arm: dict) -> str:
    return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>一万AI分享 · 飞牛 NAS 专属应用发布站 (x86 & ARM)</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 860px; margin: 40px auto; padding: 0 20px; color: #24292e; line-height: 1.6; background-color: #f6f8fa; }}
        .container {{ background: #fff; border: 1px solid #e1e4e8; border-radius: 12px; padding: 32px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); }}
        h1 {{ color: #0366d6; margin-top: 0; }}
        .card {{ background: #fafbfc; border: 1px solid #e1e4e8; border-radius: 8px; padding: 20px; margin: 20px 0; }}
        .badge {{ background: #28a745; color: white; padding: 3px 8px; border-radius: 12px; font-size: 12px; font-weight: bold; vertical-align: middle; }}
        .badge-arch {{ background: #6f42c1; color: white; padding: 3px 8px; border-radius: 12px; font-size: 12px; font-weight: bold; }}
        code {{ background: #eef1f4; padding: 4px 8px; border-radius: 6px; font-family: SFMono-Regular, Consolas, monospace; font-size: 14px; word-break: break-all; color: #d73a49; }}
        .btn-group {{ margin-top: 15px; display: flex; gap: 12px; flex-wrap: wrap; }}
        a.btn {{ display: inline-block; background: #0366d6; color: white; text-decoration: none; padding: 10px 20px; border-radius: 6px; font-weight: bold; }}
        a.btn:hover {{ background: #0256b9; }}
        a.btn-arm {{ background: #6f42c1; }}
        a.btn-arm:hover {{ background: #5a32a3; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 一万AI分享 · 飞牛 NAS 专属应用发布站</h1>
        <p>欢迎使用一万AI分享专属维护的飞牛私有云应用。现已全量支持 <strong>x86_64</strong> 与 <strong>ARM64</strong> 双架构！</p>

        <div class="card">
            <h3>🤖 DeepSeek Harness <span class="badge">{ver}</span></h3>
            <p>DeepSeek 官方 AI 开发助手与桌面工作台（一万AI分享定制版）。</p>
            <ul>
                <li><strong>内置公益端点</strong>：<code>https://api.910501.xyz/v1</code></li>
                <li><strong>预制提供商</strong>：一万AI分享（支持多个模型和自定义 API）</li>
                <li><strong>文件打通</strong>：实时互通至飞牛桌面【文件管理】&rarr;【应用文件】</li>
            </ul>
            <div class="btn-group">
                <a class="btn" href="{app_x86['download_url']}">📥 下载 x86 安装包 (.fpk)</a>
                <a class="btn btn-arm" href="{app_arm['download_url']}">📥 下载 ARM64 安装包 (.fpk)</a>
            </div>
        </div>

        <div class="card">
            <h3>📦 FnDepot 第三方应用源</h3>
            <p>在 FnDepot 的【源管理 &rarr; 添加源】中填入下面的地址即可一键安装与更新：</p>
            <p><code>https://10000ge10000.github.io/deepseek-harness-fpk/fnpack.json</code></p>
        </div>
    </div>
</body>
</html>'''


def build_fnpack(repo: str, ver: str, tag_name: str,
                 x86_fpk: str, arm_fpk: str, pkg_dir: str) -> dict:
    """生成 FnDepot (EWEDLCM/FnDepot) 外部应用源 V2 格式的 fnpack.json。

    apps 键名必须与 FPK manifest 的 appname 完全一致（deepseek-harness）；
    run_as/install_type/is_docker 与 config/privilege 声明对齐。

    兼容性说明（实测 FnDepot 0.0.7，2026-08）：JSON 直链源的 _sync_app
    按扁平字段处理，应用节点必须有顶层 version / author|distributor /
    download_url / size，否则分别报『缺少必要字段』『json 源格式无效』
    『缺少 download_url（JSON 直链源必须提供）』；releases/packages 的
    按架构分包结构保留给支持 V2 完整规范的新版客户端。
    """
    packages = {}
    for arch, fpk in (('x86', x86_fpk), ('arm', arm_fpk)):
        fingerprint = package_fingerprint(os.path.join(pkg_dir, fpk))
        packages[arch] = {
            'download_url': f'https://github.com/{repo}/releases/download/{tag_name}/{fpk}',
            'sha256': fingerprint['sha256'],
            'size': fingerprint['size'],
        }

    updated_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    return {
        'schema_version': '2',
        'source_info': {
            'name': '一万AI分享应用源',
            'author': '一万AI分享',
            'homepage': 'https://space.bilibili.com/59438380',
            'description': '一万AI分享维护的飞牛私有云 NAS 第三方应用源（x86 与 ARM64 双架构）',
        },
        'apps': {
            'deepseek-harness': {
                'display_name': 'DeepSeek Harness',
                'desc': 'DeepSeek 官方开源 AI 开发助手与桌面工作台（一万AI分享定制版）。'
                        '内置公益 API 端点开箱即用，模型与 API 均可编辑；'
                        '工作区与飞牛【文件管理】实时互通，支持局域网非安全上下文。',
                'platform': ['x86', 'arm'],
                'categories': ['AI赋能'],
                'icon_url': f'https://raw.githubusercontent.com/{repo}/main/apps/deepseek-harness/fnos/ICON_256.PNG',
                'maintainer': '一万AI分享',
                'maintainer_url': 'https://space.bilibili.com/59438380',
                # FnDepot 0.0.7 兼容字段（详见函数 docstring）
                'version': ver,
                'author': '一万AI分享',
                'distributor': '一万AI分享',
                'download_url': packages['x86']['download_url'],
                'sha256': packages['x86']['sha256'],
                # 0.0.7 的展示逻辑直接拼 "${size} MB"，顶层用 MB 取整；
                # releases/packages 内保持 V2 规范的精确字节数
                'size': round(packages['x86']['size'] / 1048576),
                'run_as': 'package',
                'install_type': '',
                'is_docker': False,
                'service_port': '3080',
                'releases': {
                    ver: {
                        'changelog': '开箱即用的公益端点与预制提供商；'
                                     '凭据权限收紧（600）；停止彻底释放端口；'
                                     '支持局域网 Polyfill 与飞牛文件管理双向互通。',
                        'updated_at': updated_at,
                        'packages': packages,
                    },
                },
            },
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description='Generate fnOS appstore index files')
    parser.add_argument('--version', required=True, help='FPK 版本号')
    parser.add_argument('--tag', required=True, help='Release tag 名')
    parser.add_argument('--x86-fpk', required=True, help='x86 安装包文件名')
    parser.add_argument('--arm-fpk', required=True, help='ARM 安装包文件名')
    parser.add_argument('--out-dir', default='public', help='输出目录')
    parser.add_argument('--pkg-dir', default='.', help='安装包所在目录（用于计算 sha256/size）')
    args = parser.parse_args()

    repo = os.environ.get('GITHUB_REPOSITORY', '10000ge10000/deepseek-harness-fpk')

    app_x86 = build_app_entry(repo, args.version, args.tag, args.x86_fpk, 'x86')
    app_arm = build_app_entry(repo, args.version, args.tag, args.arm_fpk, 'arm')

    store_data = {
        'name': '一万AI分享应用源',
        'description': '一万AI分享 飞牛私有云 NAS 第三方应用源 (支持 x86 与 ARM64 双架构)',
        'url': 'https://10000ge10000.github.io/deepseek-harness-fpk/',
        'apps': [app_x86, app_arm]
    }

    fnpack = build_fnpack(repo, args.version, args.tag, args.x86_fpk, args.arm_fpk, args.pkg_dir)

    os.makedirs(args.out_dir, exist_ok=True)
    with open(os.path.join(args.out_dir, 'appstore.json'), 'w', encoding='utf-8') as f:
        json.dump(store_data, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out_dir, 'manifests.json'), 'w', encoding='utf-8') as f:
        json.dump([app_x86, app_arm], f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out_dir, 'fnpack.json'), 'w', encoding='utf-8') as f:
        json.dump(fnpack, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out_dir, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(build_index_html(args.version, app_x86, app_arm))

    print(f'[OK] 已生成应用源文件至 {args.out_dir}/ (repo={repo}, tag={args.tag})')
    print(f'[OK] FnDepot 源: https://10000ge10000.github.io/deepseek-harness-fpk/fnpack.json')


if __name__ == '__main__':
    main()

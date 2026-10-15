# micromamba 環境構築 問題と解決策

ROS 2 jazzy 環境（Ubuntu 24.04 / システム Python 3.12）上 SAM 3D Objects 導入時の問題と、`install.sh` での対処まとめ。
`install.sh` 目的: 何も無い PC で `./install.sh` 実行のみ → チェックポイント以外のセットアップ完了。

## 前提

- Python: システム 3.12（`/usr/bin/python3`） / 要求 3.11（`bpy==4.3.0` が 3.11 専用）
- CUDA: システム 12.8（`/usr/local/cuda`） / 要求 12.1（`torch==2.5.1+cu121`、`spconv-cu121`、`kaolin` ビルド済み wheel）
- GPU: VRAM 32GB 以上必須（推論用 PC で実行）
- ROS 2 jazzy 導入済み前提

Python バージョン不一致 → システム Python に直接導入不可。micromamba で Python 3.11 隔離環境作成。

## 事前に必要なもの（install.sh 対象外）

- NVIDIA ドライバ: CUDA 12.1 対応（530 以上）。conda では入らない
- コマンド: `curl` `tar` `bzip2`（micromamba 取得用）、`git`（pip の git+ 依存: pytorch3d、MoGe、gsplat）
  - 不足時 install.sh がエラー停止 → `sudo apt install <不足コマンド>`

---

## 1. micromamba 未導入 / conda 混在

### 問題

- 白紙 PC には micromamba も conda も無し → 手動導入必要だと「install.sh 一発」不成立
- 既存 conda（Anaconda / Miniconda）使用時、defaults チャンネル ToS 未同意で非対話 `env create` 失敗の恐れ
- micromamba 1.x は `env create` 非対応の場合あり

### 解決策（install.sh 実装済み）

- conda 有無に関係なく常に micromamba 使用
- `.micromamba/bin/micromamba` 不在時、公式静的バイナリ（2.x）自動取得

  ```bash
  curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C .micromamba bin/micromamba
  ```

- 配置先はリポジトリ内 `.micromamba/`（詳細は「2. micromamba 配置先」）
  - バイナリ: `.micromamba/bin/micromamba`
  - root prefix（パッケージキャッシュ含む）: `.micromamba`（既存の `MAMBA_ROOT_PREFIX` は無視）
  - 環境: `.micromamba/envs/sam3d-objects`
- 環境作成 `micromamba create -y -p .micromamba/envs/sam3d-objects -f environments/default.yml`（名前ではなくパス指定）
- 存在確認 `.micromamba/envs/sam3d-objects/bin/python` 有無。既存なら作成スキップ（`default.yml` 変更は反映されない → 作り直す場合 `rm -rf .micromamba/envs/sam3d-objects`）

### 注意

- shell init しない → `~/.bashrc` 無変更
- activate はパス指定 → `MAMBA_ROOT_PREFIX` 未設定でも環境が見つかる
- 環境作成途中で失敗 → `.micromamba/envs/sam3d-objects` が中途半端に残る（`bin/python` 無しなら再作成対象）→ 再実行時 `create` 失敗の恐れ。その場合 `rm -rf .micromamba/envs/sam3d-objects` → `./install.sh` 再実行

---

## 2. micromamba 配置先（`~` かリポジトリ内か）

### 問題

公式 installer 既定値（`~/.local/bin/micromamba`、`~/micromamba`）に置く場合の問題:

- Docker コンテナ内で作業、ホストからバインドマウントは `~/colcon_ws/src` のみ。`~` はコンテナレイヤー（overlay）上 → `docker rm` / `compose down` / イメージ再作成で micromamba・環境（10GB 超）消失 → install.sh 再実行（ソースビルド込みで長時間）
- 使用時に毎回 `export MAMBA_ROOT_PREFIX=~/micromamba` 必要。忘れると micromamba 2.x は別の既定 root 参照 → 環境が見つからない
- 環境名 `sam3d-objects` が全体共有 → 複数 clone で同一環境取り合い、`pip install -e` 参照先が最後に install.sh 実行した clone に上書き
- リポジトリ削除後も `~/micromamba` 残存

### 解決策（install.sh 実装済み）

- micromamba バイナリ・パッケージキャッシュ・環境すべてリポジトリ内 `.micromamba/` に配置 → ホスト側に永続化、clone 毎に独立、`rm -rf` で完全削除
- 環境はパス指定で作成・activate（`-p`）
- リポジトリは colcon_ws/src 配下 → colcon が環境内（数万ファイル）まで走査し低速化・`setup.py` / `package.xml` 誤検出の恐れ → install.sh が `.micromamba/COLCON_IGNORE` 作成
- `.gitignore` に `.micromamba/` 追加済み

### 注意

- conda 環境は prefix を内部に埋め込む → リポジトリ移動・改名で環境破損（`pip install -e` も同様にリポジトリパス依存）。移動後は `rm -rf .micromamba/envs/sam3d-objects` → `./install.sh` 再実行
- VSCode でファイル監視・Pylance 索引・検索が重い場合、`files.watcherExclude` / `search.exclude` に `**/.micromamba/**` 追加
- `~/.condarc` / `~/.mambarc` はリポジトリ内配置でも読み込まれる
- ホストとコンテナで UID が異なる場合、`.micromamba/` 所有権に注意
- 旧 install.sh（`~` 配置）で作成済みの環境は引き継がれない → 再実行時リポジトリ内に新規作成。旧環境不要なら `rm -rf ~/micromamba ~/.local/bin/micromamba` で削除

---

## 3. `micromamba shell init` で ROS 環境破壊

### 問題

`micromamba shell init` → `~/.bashrc` にフック追記 → シェル起動時 `python`、`pip`、ライブラリが micromamba 側に置換。

- `colcon build` が Python 3.11 使用 → ROS パッケージのビルド・import 失敗
- conda 環境の `libstdc++`、`libssl` 等が優先リンク → ROS ノード起動時シンボルエラー

### 解決策

- `micromamba shell init` 実行禁止（`~/.bashrc` 追記しない）
- 必要時のみ、そのシェル内で hook 読込 → activate
- install.sh も同方式（スクリプト内で `shell hook` を `eval`）→ `~/.bashrc` 無変更
- SAM 3D Objects 用ターミナルと ROS 用ターミナル分離

---

## 4. `PYTHONPATH` に Python 3.12 パス混入（最重要）

### 問題

`~/.bashrc` の以下 2 設定が `PYTHONPATH` に Python 3.12 site-packages 追加。

```bash
export PYTHONPATH=/opt/pytorch/.venv/lib/python3.12/site-packages:$PYTHONPATH
source /ros_entrypoint.sh   # /opt/ros/jazzy/lib/python3.12/site-packages などを追加
```

`PYTHONPATH` は activate でも消えない → Python 3.11 環境から以下を読込。

- `/opt/pytorch/.venv` の Python 3.12 用 `torch`
- ROS の `numpy`、`rclpy` 等

結果:

- `ImportError: ... undefined symbol` 等 C 拡張 ABI 不一致
- `pip install` 依存解決で「インストール済み」誤判定

### 解決策（install.sh 実装済み）

- install.sh 冒頭で `unset PYTHONPATH`、`PYTHONNOUSERSITE=1`
- 環境の `etc/conda/activate.d/sam3d_env.sh` で activate 毎に退避 → unset、`deactivate.d/sam3d_env.sh` で復元
- `PYTHONNOUSERSITE=1` → `~/.local/lib/python3.11` の user site も無効

確認:

```bash
python -c "import sys, torch; print(sys.version); print(torch.__file__, torch.version.cuda)"
# torch.__file__ が環境内パス、torch.version.cuda が 12.1
```

---

## 5. `LD_LIBRARY_PATH` / `LIBRARY_PATH` にシステム CUDA 12.8・ROS ライブラリ混入

### 問題

ROS 環境のシェルには以下が設定済み。

- `LD_LIBRARY_PATH`: `/opt/ros/jazzy/lib`、`/usr/local/cuda/lib64`（12.8）、OpenCV 等
- `LIBRARY_PATH`: `/usr/local/cuda/lib64/stubs`（12.8）

`LD_LIBRARY_PATH` は RUNPATH より優先 → 実行時に環境外の so 読込。`LIBRARY_PATH` → pytorch3d 等ソースビルド時に 12.8 ライブラリへリンクの恐れ。

### 解決策（install.sh 実装済み）

- install.sh 冒頭で `unset LD_LIBRARY_PATH LIBRARY_PATH`
- activate.d / deactivate.d で `PYTHONPATH` と同様に退避・unset・復元
- NVIDIA ドライバの `libcuda.so` は `/usr/lib/x86_64-linux-gnu` → unset しても影響無し

---

## 6. CUDA toolkit 不一致（12.8 と 12.1）

### 問題

`environments/default.yml` に CUDA 12.1 `nvcc` 同梱。システムには `/usr/local/cuda`（12.8）。

`pytorch3d`、`flash_attn`、`gsplat` ソースビルド時 `torch.utils.cpp_extension` は `CUDA_HOME` 参照。未設定 or システム側指定 → 12.8 使用 → torch（cu121）と不一致でビルド・実行時エラー。

### 解決策（install.sh 実装済み）

- install.sh 内と activate.d で `CUDA_HOME=$CONDA_PREFIX`、deactivate.d で復元
- `FORCE_CUDA=1` → GPU 非可視でも CUDA 拡張ビルド（未設定だと実行時 `RuntimeError: Not compiled with GPU support`）
- install.sh 最後で `nvcc --version` が release 12.1 か検証

確認:

```bash
which nvcc        # $CONDA_PREFIX/bin/nvcc
nvcc --version    # release 12.1
```

---

## 7. 環境外 pip で導入

### 問題

未 activate で `pip install` → システム pip（Python 3.12）使用。Ubuntu 24.04 は PEP 668 で失敗。

```
error: externally-managed-environment
```

`--break-system-packages` 付与 → ROS 依存パッケージ上書き → ROS 環境破壊。

### 解決策（install.sh 実装済み）

- `--break-system-packages` 使用禁止
- install.sh は pip 前に `which python` が `$CONDA_PREFIX/bin/python` か検証、違えばエラー停止
- `pip` ではなく `python -m pip` 使用
- 手動で追加導入する場合も事前確認

  ```bash
  which python pip   # どちらも .../envs/sam3d-objects/bin/
  ```

---

## 推奨手順（推論用 PC）

```bash
# 1. セットアップ（micromamba 導入・環境作成・依存導入・検証まで）
./install.sh
# チェックポイントは doc/setup.md「2. Getting Checkpoints」に従い手動ダウンロード

# 2. 使用時（ROS 用とは別ターミナル）
cd ~/colcon_ws/src/sam-3d-objects
eval "$(.micromamba/bin/micromamba shell hook --shell bash)"
micromamba activate "$PWD/.micromamba/envs/sam3d-objects"
python demo.py
```

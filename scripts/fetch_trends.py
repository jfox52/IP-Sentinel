import urllib.request
import xml.etree.ElementTree as ET
import os
import json
import re

# ================== [路径防弹装甲] ==================
# 无论在哪里执行该脚本，都能精准反推项目根目录
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

MAP_JSON_PATH = os.path.join(PROJECT_ROOT, "data", "map.json")
DATA_DIR = os.path.join(PROJECT_ROOT, "data", "keywords")
# ====================================================

# 特殊战区代码映射 (Google Trends RSS 要求)
GEO_FIX = {'UK': 'GB'}

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

def get_active_regions():
    """动态提取 map.json 中的战区 (适配 v3.5.0 大洲战区降维架构)"""
    try:
        with open(MAP_JSON_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
            regions = []
            # 第一层穿透：遍历所有大洲战区 (continents)
            for continent in data.get('continents', []):
                # 第二层穿透：遍历大洲下的所有国家 (countries)
                for country in continent.get('countries', []):
                    if 'id' in country:
                        regions.append(country['id'])
            return regions
    except Exception as e:
        print(f"❌ [读取地图失败]: {e}")
        return []

def fetch_trends(region_code):
    """从 Google Trends 抓取当日热搜"""
    geo = GEO_FIX.get(region_code, region_code)
    url = f"https://trends.google.com/trending/rss?geo={geo}"
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=10) as response:
            xml_data = response.read()
            root = ET.fromstring(xml_data)
            return [re.sub(r'[\n\r\t]', ' ', item.find('title').text).strip() 
                    for item in root.findall('./channel/item') 
                    if item.find('title') is not None]
    except Exception as e:
        print(f"⚠️ {region_code} 抓取异常: {e}")
        return []

def update_file(region, new_words):
    """滑动窗口更新，保留 200 条最热记录"""
    os.makedirs(DATA_DIR, exist_ok=True)
    file_path = os.path.join(DATA_DIR, f"kw_{region}.txt")
    old_words = []
    if os.path.exists(file_path):
        with open(file_path, 'r', encoding='utf-8') as f:
            old_words = [l.strip() for l in f if l.strip()]
    
    # 新词排在最前面，去重
    combined = new_words + [w for w in old_words if w not in new_words]
    final_list = combined[:200]
    
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(final_list) + '\n')
    print(f"✅ [同步完成] {region}: 注入 {len(new_words)} 条新热点")

if __name__ == '__main__':
    regions = get_active_regions()
    if not regions:
        print("🛑 未发现活跃战区，请检查 map.json")
        exit(1)
    
    for r in regions:
        print(f"📡 正在拉取 {r} 战区情报...")
        words = fetch_trends(r)
        if words:
            update_file(r, words)
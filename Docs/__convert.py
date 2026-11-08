import os
import re
import glob
import pathlib

PATH = pathlib.Path(__file__).parent.resolve()

for file in glob.glob(os.path.join(PATH, '*.mdx')):
    with open(file, 'r', encoding='utf-8') as f:
        content = f.read()

    content = re.sub(r'^---.*?---\s*', '', content, flags=re.DOTALL)

    new_file = file.replace('.mdx', '.md')
    with open(new_file, 'w', encoding='utf-8') as f:
        f.write(content)

    os.remove(file)
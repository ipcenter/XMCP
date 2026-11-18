import json
import sys


def strip_comments(text):
    """去掉 # 到行尾的注释（字符串里的 # 不动）。"""
    out = []
    i = 0
    n = len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def drop_trailing_commas(text):
    """去掉 ] 或 } 前面多余的逗号。"""
    out = []
    i = 0
    n = len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "]}":
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def sanitize(text):
    return drop_trailing_commas(strip_comments(text))


def main():
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            text = f.read()
        has_comment = strip_comments(text) != text
        data = json.loads(sanitize(text))
        # 带 # 注释的文件不重新排版（dumps 只会输出解析结果，会把注释丢掉），原样返回
        if has_comment:
            out = text
        else:
            out = json.dumps(data, indent=2, ensure_ascii=False)
        with open(path + ".fmt", "w", encoding="utf-8", newline="\n") as f:
            f.write(out.rstrip() + "\n")
        return 0
    except Exception as e:
        print(str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())

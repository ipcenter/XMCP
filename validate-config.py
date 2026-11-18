import json, sys


def strip_comments(text):
    """去掉 # 到行尾的注释（字符串里的 # 不动）。换行保留，所以报错行号仍然准确。"""
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
    """去掉 ] 或 } 前面多余的逗号（如 ["a", # 注释 换行 ] 剥掉注释后留下的尾巴）。"""
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


def emit(msg, msgfile):
    if msgfile:
        try:
            with open(msgfile, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
        except Exception:
            pass
    try:
        print(msg)
    except Exception:
        pass


def main():
    path = sys.argv[1]
    msgfile = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            text = f.read()
        json.loads(sanitize(text))
        return 0
    except json.JSONDecodeError as e:
        emit("第 %d 行第 %d 列附近: %s" % (e.lineno, e.colno, e.msg), msgfile)
        return 1
    except Exception as e:
        emit(str(e), msgfile)
        return 1


if __name__ == "__main__":
    sys.exit(main())

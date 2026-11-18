#include "ctaglib.h"

#include <cstdio>
#include <cstring>
#include <string>

#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>
#include <taglib/tstring.h>

namespace {

void copyField(char *dst, size_t size, const TagLib::String &s) {
    std::string utf8 = s.to8Bit(true);
    std::strncpy(dst, utf8.c_str(), size - 1);
    dst[size - 1] = '\0';
}

TagLib::String firstValue(const TagLib::PropertyMap &props, const char *key) {
    auto it = props.find(key);
    if (it == props.end() || it->second.isEmpty()) {
        return TagLib::String();
    }
    return it->second.front();
}

}  // namespace

extern "C" ctag_info ctag_read(const char *path) {
    ctag_info info;
    std::memset(&info, 0, sizeof(info));
    TagLib::FileRef ref(path, true, TagLib::AudioProperties::Average);
    if (ref.isNull()) {
        return info;
    }
    info.ok = 1;
    if (ref.audioProperties()) {
        info.duration = ref.audioProperties()->lengthInMilliseconds() / 1000.0;
    }
    if (!ref.tag()) {
        return info;
    }
    const TagLib::PropertyMap props = ref.file()->properties();
    copyField(info.title, sizeof(info.title), firstValue(props, "TITLE"));
    copyField(info.artist, sizeof(info.artist), firstValue(props, "ARTIST"));
    TagLib::String key = firstValue(props, "INITIALKEY");
    if (key.isEmpty()) {
        key = firstValue(props, "KEY");
    }
    copyField(info.key, sizeof(info.key), key);
    TagLib::String bpm = firstValue(props, "BPM");
    if (!bpm.isEmpty()) {
        std::string s = bpm.to8Bit(true);
        for (char &c : s) {
            if (c == ',') c = '.';
        }
        info.bpm = std::atof(s.c_str());
    }
    return info;
}

extern "C" int ctag_write(const char *path, const char *key, double bpm) {
    TagLib::FileRef ref(path, false);
    if (ref.isNull()) {
        return 0;
    }
    TagLib::PropertyMap props = ref.file()->properties();
    if (key && *key) {
        props.replace("INITIALKEY", TagLib::StringList(TagLib::String(key, TagLib::String::UTF8)));
    }
    if (bpm > 0) {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.2f", bpm);
        std::string s(buf);
        while (!s.empty() && s.back() == '0') s.pop_back();
        if (!s.empty() && s.back() == '.') s.pop_back();
        props.replace("BPM", TagLib::StringList(TagLib::String(s)));
    }
    ref.file()->setProperties(props);
    return ref.save() ? 1 : 0;
}

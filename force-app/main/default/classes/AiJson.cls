/**
 * Safe helpers for reading AI (prompt template) JSON responses.
 * Every getter returns null instead of throwing on a missing key, wrong type or bad format.
 */
public class AiJson {

    public static Map<String, Object> parse(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.replace(' ', ' ')
                      .replaceAll('```json', '')
                      .replaceAll('```', '')
                      .trim();
        Integer first = s.indexOf('{');
        Integer last = s.lastIndexOf('}');
        if (first < 0 || last <= first) return null;
        s = s.substring(first, last + 1);
        try {
            Object o = JSON.deserializeUntyped(s);
            return o instanceof Map<String, Object> ? (Map<String, Object>) o : null;
        } catch (Exception e) {
            return null;
        }
    }

    /** 'Resume', 'Job Description', 'Other' or null when the prompt did not say. */
    public static String documentType(String raw) {
        Map<String, Object> m = parse(raw);
        if (m == null) return null;
        String t = str(m, 'documentType');
        if (t == null) return null;
        String n = t.toLowerCase().replaceAll('[^a-z]', '');
        if (n == 'resume' || n == 'cv' || n == 'candidate') return 'Resume';
        if (n == 'jobdescription' || n == 'jd' || n == 'job') return 'Job Description';
        return 'Other';
    }

    public static String str(Map<String, Object> m, String key) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) return null;
        Object v = m.get(key);
        String s = (v instanceof String) ? (String) v : String.valueOf(v);
        s = s.trim();
        if (s == '' || s.equalsIgnoreCase('null') || s.equalsIgnoreCase('unknown') || s.equalsIgnoreCase('n/a')
                || s.equalsIgnoreCase('none') || s == '-') return null;
        return s;
    }

    public static Map<String, Object> obj(Map<String, Object> m, String key) {
        if (m == null) return null;
        Object v = m.get(key);
        return v instanceof Map<String, Object> ? (Map<String, Object>) v : null;
    }

    public static List<Map<String, Object>> objList(Map<String, Object> m, String key) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (m == null) return out;
        Object v = m.get(key);
        if (v instanceof List<Object>) {
            for (Object o : (List<Object>) v) {
                if (o instanceof Map<String, Object>) out.add((Map<String, Object>) o);
            }
        }
        return out;
    }

    public static List<String> strList(Map<String, Object> m, String key) {
        List<String> out = new List<String>();
        if (m == null) return out;
        Object v = m.get(key);
        if (v instanceof List<Object>) {
            for (Object o : (List<Object>) v) {
                if (o != null && String.isNotBlank(String.valueOf(o))) out.add(String.valueOf(o).trim());
            }
        } else if (v != null && String.isNotBlank(String.valueOf(v))) {
            out.add(String.valueOf(v).trim());
        }
        return out;
    }

    /** Accepts YYYY-MM-DD, YYYY-MM, DD/MM/YYYY, DD-MM-YYYY, MMM-YYYY. Returns null otherwise. */
    public static Date toDate(Object raw) {
        if (raw == null) return null;
        String s = String.valueOf(raw).trim();
        if (s == '') return null;
        try {
            if (Pattern.matches('\\d{4}-\\d{1,2}-\\d{1,2}', s)) return Date.valueOf(s);
            if (Pattern.matches('\\d{4}-\\d{1,2}', s)) return Date.valueOf(s + '-01');
            Matcher dm = Pattern.compile('^(\\d{1,2})[/\\-.](\\d{1,2})[/\\-.](\\d{4})$').matcher(s);
            if (dm.matches()) {
                return Date.newInstance(Integer.valueOf(dm.group(3)), Integer.valueOf(dm.group(2)), Integer.valueOf(dm.group(1)));
            }
            Matcher my = Pattern.compile('^(?i)([a-z]{3,9})[\\s\\-/]+(\\d{4})$').matcher(s);
            if (my.matches()) {
                Integer mon = monthOf(my.group(1));
                if (mon != null) return Date.newInstance(Integer.valueOf(my.group(2)), mon, 1);
            }
        } catch (Exception e) {
            return null;
        }
        return null;
    }

    /** First number found: "3-5 years" -> 3, "6.5 yrs" -> 6.5, "3+" -> 3. */
    public static Decimal toNumber(Object raw) {
        if (raw == null) return null;
        Matcher m = Pattern.compile('(\\d+(?:\\.\\d+)?)').matcher(String.valueOf(raw));
        if (m.find()) {
            try { return Decimal.valueOf(m.group(1)); } catch (Exception e) { return null; }
        }
        return null;
    }

    public static String digitsOnly(String phone) {
        if (String.isBlank(phone)) return null;
        String d = phone.replaceAll('[^0-9]', '');
        if (d.length() < 7) return null;
        // keep the last 10 digits so +91 98xxxx and 98xxxx match
        return d.length() > 10 ? d.right(10) : d;
    }

    public static String normalizeEmail(String email) {
        if (String.isBlank(email)) return null;
        String e = email.trim().toLowerCase();
        return Pattern.matches('^[a-z0-9._%+\\-]+@[a-z0-9.\\-]+\\.[a-z]{2,}$', e) ? e : null;
    }

    public static String normalizeUrl(String url) {
        if (String.isBlank(url)) return null;
        String u = url.trim().toLowerCase().replaceFirst('^https?://', '').replaceFirst('^www\\.', '');
        return u.removeEnd('/');
    }

    private static Integer monthOf(String m) {
        List<String> names = new List<String>{ 'jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec' };
        Integer i = names.indexOf(m.toLowerCase().left(3));
        return i < 0 ? null : i + 1;
    }
}
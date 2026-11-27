/**
 * Plain text of a Word (.docx) file, read in Apex (27-11-2026).
 * Used when Einstein returns empty data for a .docx it could not read (e.g. JD_InfosysLtd.docx):
 * IntakeProcessor then gives the AI a PDF "text copy" of the same document.
 */
public with sharing class DocxText {

    /** Text of word/document.xml: one line per paragraph, table cells separated by " | ". Null when not a readable .docx. */
    public static String extract(Blob docx) {
        if (docx == null || docx.size() == 0) return null;
        try {
            Compression.ZipReader reader = new Compression.ZipReader(docx);
            Compression.ZipEntry entry = reader.getEntry('word/document.xml');
            if (entry == null) return null;
            return fromXml(reader.extract(entry).toString());
        } catch (Exception e) {
            UtilityClass.createElog(e, 'DocxText', 'extract');
            return null;
        }
    }

    @TestVisible
    private static String fromXml(String xml) {
        if (String.isBlank(xml)) return null;
        String t = xml
            .replaceAll('<w:tab/>', ' ')
            .replaceAll('<w:br[^>]*/>', '\n')
            .replaceAll('</w:tc>', ' | ')
            .replaceAll('</w:p>', '\n')
            .replaceAll('<[^>]+>', '');
        t = t.unescapeXml().replaceAll('[ \\t]+', ' ').replaceAll('\\s*\\|\\s*\\n', '\n').replaceAll('\\n\\s*\\n+', '\n\n').trim();
        return String.isBlank(t) ? null : t;
    }
}
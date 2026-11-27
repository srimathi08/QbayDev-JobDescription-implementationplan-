import { LightningElement } from 'lwc';
import search from '@salesforce/apex/CandidateSearchController.search';
import summarize from '@salesforce/apex/CandidateSearchController.summarize';
import candidate360 from '@salesforce/apex/CandidateSearchController.candidate360';
import route from '@salesforce/apex/DataAskService.route';
import ask from '@salesforce/apex/DataAskService.ask';

const PAGE_SIZE = 10;
const EXAMPLES = [
    'How many opportunities were created last week?',
    'Salesforce developer Chennai 5+ years',
    'Interviews scheduled this month',
    'Clients added this year',
    'Candidates with Platform Developer certification'
];
const ASK_EXAMPLES = ['Who is the best fit for a senior LWC role?', 'Compare the top 3', 'Who has the most certifications?'];

/**
 * Magic Search v3 (27-11-2026): one box for every question.
 *  - People search ("Salesforce developer Chennai 5+ years"): ranked candidates, Ask AI, Candidate 360 view.
 *  - Data question ("How many opportunities were created last week?"): Einstein writes a query from the
 *    real field list of the matching objects; it runs with the user's own access (DataAskService).
 */
export default class SearchablityUsingAi extends LightningElement {
    searchKey = '';
    lastQuery = '';
    types = ['Candidates'];
    mode; // 'people' | 'data'
    // people
    results = [];
    keywords = [];
    minYears;
    page = 1;
    question = '';
    answerHtml = '';
    answerLoading = false;
    // data
    dataAnswer;
    // shared
    searched = false;
    isLoading = false;
    loadingText = '';
    errorMessage = '';
    // 360
    profile;
    profileLoading = false;
    showProfile = false;

    typeOptions = [
        { label: 'Candidates', value: 'Candidates' },
        { label: 'Employees', value: 'Employee' },
        { label: 'Contractors', value: 'Contractor' }
    ];

    // ---------------- view state ----------------

    get typeButtons() {
        return this.typeOptions.map((o) => ({
            ...o,
            cls: 'qb-segment-btn' + (this.types.includes(o.value) ? ' is-active' : '')
        }));
    }
    get examples() {
        return EXAMPLES.map((e) => ({ label: e }));
    }
    get askExamples() {
        return ASK_EXAMPLES.map((e) => ({ label: e }));
    }
    get searchDisabled() {
        return this.isLoading || !this.searchKey || !this.searchKey.trim();
    }
    get isPeople() {
        return this.mode === 'people' && this.results.length > 0;
    }
    get isData() {
        return this.mode === 'data' && !!this.dataAnswer && this.dataAnswer.totalCount > 0;
    }
    get showStart() {
        return !this.searched && !this.isLoading;
    }
    get noResults() {
        return this.searched && !this.isLoading && !this.errorMessage
            && ((this.mode === 'people' && this.results.length === 0) || (this.mode === 'data' && this.dataAnswer && this.dataAnswer.totalCount === 0));
    }
    get showClear() {
        return this.searched || !!this.searchKey;
    }
    get understoodText() {
        if (this.mode === 'data') {
            return this.dataAnswer && this.dataAnswer.note ? this.dataAnswer.note : '';
        }
        const parts = [];
        if (this.keywords.length) {
            parts.push('keywords: ' + this.keywords.join(', '));
        }
        if (this.minYears !== undefined && this.minYears !== null) {
            parts.push(`at least ${this.minYears} years of experience`);
        }
        return parts.length ? 'Searched people for ' + parts.join('; ') + '.' : '';
    }
    get countText() {
        const n = this.results.length;
        return `${n} ${n === 1 ? 'person' : 'people'}` + (n >= 100 ? ' (top 100)' : '');
    }
    get askDisabled() {
        return this.answerLoading || this.results.length === 0;
    }

    // ---------------- people: paging and cards ----------------

    get pageCount() {
        return Math.max(1, Math.ceil(this.results.length / PAGE_SIZE));
    }
    get pageRows() {
        const start = (this.page - 1) * PAGE_SIZE;
        const total = this.keywords.length;
        return this.results.slice(start, start + PAGE_SIZE).map((r) => ({
            ...r,
            url: `/${r.id}`,
            resumeUrl: r.resumeId ? `/lightning/r/ContentDocument/${r.resumeId}/view` : null,
            initials: this.initials(r.name),
            experienceText: r.experience !== undefined && r.experience !== null ? `${r.experience} yrs` : 'Exp. not given',
            matchText: total ? `${r.score}/${total} match` : '',
            matchWords: total ? r.matched.join(', ') : '',
            matchClass: total && r.score === total ? 'qb-pill qb-pill-success' : 'qb-pill',
            hasSkills: r.skills && r.skills.length > 0,
            hasCerts: r.certifications && r.certifications.length > 0,
            meta: [r.designation, r.location, r.organization].filter((x) => x).join(' · ')
        }));
    }
    get showPager() {
        return this.results.length > PAGE_SIZE;
    }
    get pageText() {
        return `Page ${this.page} of ${this.pageCount}`;
    }
    get prevDisabled() {
        return this.page <= 1;
    }
    get nextDisabled() {
        return this.page >= this.pageCount;
    }
    handlePrev() {
        if (this.page > 1) {
            this.page -= 1;
        }
    }
    handleNext() {
        if (this.page < this.pageCount) {
            this.page += 1;
        }
    }

    // ---------------- data answer table ----------------

    get dataTitle() {
        return this.dataAnswer ? this.dataAnswer.title : '';
    }
    get dataCountText() {
        if (!this.dataAnswer) {
            return '';
        }
        const n = this.dataAnswer.totalCount;
        const shown = this.dataAnswer.rows.length;
        return `${n} ${n === 1 ? 'record' : 'records'}` + (n > shown ? ` · showing the first ${shown}` : '');
    }
    get dataColumns() {
        if (!this.dataAnswer) {
            return [];
        }
        return this.dataAnswer.columns.map((c) => {
            if (c.type === 'name') {
                return { label: c.label, fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: c.fieldName }, target: '_blank' } };
            }
            if (c.type === 'date') {
                return { label: c.label, fieldName: c.fieldName, type: 'date-local', typeAttributes: { day: '2-digit', month: 'short', year: 'numeric' } };
            }
            if (c.type === 'datetime') {
                return { label: c.label, fieldName: c.fieldName, type: 'date', typeAttributes: { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' } };
            }
            return { label: c.label, fieldName: c.fieldName, type: c.type };
        });
    }
    get dataRows() {
        return this.dataAnswer ? this.dataAnswer.rows : [];
    }
    get hasDataRows() {
        return this.dataRows.length > 0;
    }
    get querySoql() {
        return this.dataAnswer ? this.dataAnswer.soql : '';
    }

    // ---------------- actions ----------------

    handleSearchChange(event) {
        this.searchKey = event.target.value;
    }
    handleKeyUp(event) {
        if (event.key === 'Enter' && !this.searchDisabled) {
            this.runSearch();
        }
    }
    handleTypeClick(event) {
        const v = event.currentTarget.dataset.value;
        const next = this.types.includes(v) ? this.types.filter((t) => t !== v) : [...this.types, v];
        this.types = next.length ? next : ['Candidates'];
        if (this.searched && this.mode === 'people') {
            this.runSearch();
        }
    }
    handleExample(event) {
        this.searchKey = event.currentTarget.dataset.label;
        this.runSearch();
    }
    handleClear() {
        this.searchKey = '';
        this.lastQuery = '';
        this.mode = undefined;
        this.results = [];
        this.keywords = [];
        this.minYears = null;
        this.dataAnswer = undefined;
        this.searched = false;
        this.errorMessage = '';
        this.question = '';
        this.answerHtml = '';
        this.page = 1;
    }

    async runSearch() {
        if (this.searchDisabled) {
            return;
        }
        const q = this.searchKey.trim();
        this.lastQuery = q;
        this.isLoading = true;
        this.loadingText = 'Understanding your question...';
        this.errorMessage = '';
        this.answerHtml = '';
        this.dataAnswer = undefined;
        this.results = [];
        try {
            const kind = await route({ question: q });
            if (kind === 'data') {
                this.loadingText = 'Asking Einstein and searching your records...';
                try {
                    this.dataAnswer = await ask({ question: q });
                    this.mode = 'data';
                } catch (e) {
                    // not about a record type after all: fall back to the people search
                    if (this.errorText(e).includes('which records')) {
                        await this.peopleSearch(q);
                    } else {
                        throw e;
                    }
                }
            } else {
                await this.peopleSearch(q);
            }
            this.searched = true;
        } catch (e) {
            this.errorMessage = this.errorText(e);
            this.searched = true;
        } finally {
            this.isLoading = false;
        }
    }

    async peopleSearch(q) {
        this.loadingText = 'Searching people...';
        const resp = await search({ query: q, recordTypes: this.types });
        this.mode = 'people';
        this.results = resp.results || [];
        this.keywords = resp.keywords || [];
        this.minYears = resp.minYears;
        this.page = 1;
    }

    // ---------------- ask AI about people results ----------------

    handleQuestion(event) {
        this.question = event.target.value;
    }
    handleAskKeyUp(event) {
        if (event.key === 'Enter' && !this.askDisabled) {
            this.handleAsk();
        }
    }
    handleAskExample(event) {
        this.question = event.currentTarget.dataset.label;
        this.handleAsk();
    }
    async handleAsk() {
        this.answerLoading = true;
        this.answerHtml = '';
        const q = this.question && this.question.trim() ? this.question.trim() : 'Summarise these results: ' + this.lastQuery;
        try {
            this.answerHtml = await summarize({ query: q, accountIds: this.results.map((r) => r.id) });
        } catch (e) {
            this.answerHtml = `<p>${this.errorText(e)}</p>`;
        } finally {
            this.answerLoading = false;
        }
    }

    // ---------------- candidate 360 ----------------

    async open360(event) {
        const id = event.currentTarget.dataset.id;
        this.showProfile = true;
        this.profileLoading = true;
        this.profile = undefined;
        try {
            const p = await candidate360({ accountId: id });
            this.profile = {
                ...p,
                url: `/${p.id}`,
                initials: this.initials(p.name),
                experienceText: p.experience !== undefined && p.experience !== null ? `${p.experience} yrs experience` : '',
                facts: [p.designation, p.organization, p.location].filter((x) => x).join(' · '),
                sections: p.sections.map((s) => ({
                    ...s,
                    hasItems: s.items.length > 0,
                    items: s.items.map((it) => ({
                        ...it,
                        url: s.title === 'Files' ? `/lightning/r/ContentDocument/${it.id}/view` : `/${it.id}`
                    }))
                }))
            };
        } catch (e) {
            this.profile = { error: this.errorText(e), sections: [] };
        } finally {
            this.profileLoading = false;
        }
    }
    close360() {
        this.showProfile = false;
    }

    // ---------------- utils ----------------

    initials(name) {
        return (name || '?')
            .split(' ')
            .filter((w) => w)
            .slice(0, 2)
            .map((w) => w[0].toUpperCase())
            .join('');
    }

    errorText(e) {
        if (e && e.body) {
            if (Array.isArray(e.body)) {
                return e.body.map((b) => b.message).join(', ');
            }
            if (e.body.message) {
                return e.body.message;
            }
        }
        return (e && e.message) || 'Something went wrong. Please try again.';
    }
}

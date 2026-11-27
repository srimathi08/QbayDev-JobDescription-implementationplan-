import { LightningElement } from 'lwc';
import search from '@salesforce/apex/CandidateSearchController.search';
import summarize from '@salesforce/apex/CandidateSearchController.summarize';

const PAGE_SIZE = 10;
const EXAMPLES = [
    'Salesforce developer Chennai 5+ years',
    'LWC Apex integration',
    'Platform Developer certified',
    'Java Spring Boot 3 years'
];
const ASK_EXAMPLES = ['Who is the best fit for a senior LWC role?', 'Compare the top 3', 'Who has the most certifications?'];

/**
 * Magic Search v2 (26-11-2026, look and Ask AI 27-11-2026).
 * Search: safe ranked search in Apex (CandidateSearchController) over candidates, skills, certifications, projects.
 * Ask AI: optional question about the results found (top 20), answered by Einstein from those records only.
 */
export default class SearchablityUsingAi extends LightningElement {
    searchKey = '';
    types = ['Candidates'];
    results = [];
    keywords = [];
    minYears;
    searched = false;
    isLoading = false;
    errorMessage = '';
    page = 1;
    question = '';
    answer = '';
    answerLoading = false;

    typeOptions = [
        { label: 'Candidates', value: 'Candidates' },
        { label: 'Employees', value: 'Employee' },
        { label: 'Contractors', value: 'Contractor' }
    ];

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
    get hasResults() {
        return this.results.length > 0;
    }
    get noResults() {
        return this.searched && !this.isLoading && !this.errorMessage && this.results.length === 0;
    }
    get showClear() {
        return this.searched || !!this.searchKey;
    }
    get understoodText() {
        const parts = [];
        if (this.keywords.length) {
            parts.push('keywords: ' + this.keywords.join(', '));
        }
        if (this.minYears !== undefined && this.minYears !== null) {
            parts.push(`at least ${this.minYears} years of experience`);
        }
        return parts.length ? 'Searched for ' + parts.join('; ') + '.' : '';
    }
    get countText() {
        const n = this.results.length;
        return `${n} ${n === 1 ? 'match' : 'matches'}` + (n >= 100 ? ' (top 100)' : '');
    }
    get askDisabled() {
        return this.answerLoading || !this.hasResults;
    }

    // ---------------- paging ----------------

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
            initials: (r.name || '?')
                .split(' ')
                .filter((w) => w)
                .slice(0, 2)
                .map((w) => w[0].toUpperCase())
                .join(''),
            experienceText: r.experience !== undefined && r.experience !== null ? `${r.experience} yrs` : 'Exp. not given',
            matchText: total ? `Matches ${r.score} of ${total}` : '',
            matchWords: total ? r.matched.join(', ') : '',
            matchClass: total && r.score === total ? 'qb-pill qb-pill-success' : 'qb-pill qb-pill-warning',
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

    // ---------------- search ----------------

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
        if (this.searched) {
            this.runSearch();
        }
    }
    handleExample(event) {
        this.searchKey = event.currentTarget.dataset.label;
        this.runSearch();
    }

    /** "Clear": back to an empty search (the refresh the user asked for). */
    handleClear() {
        this.searchKey = '';
        this.results = [];
        this.keywords = [];
        this.minYears = null;
        this.searched = false;
        this.errorMessage = '';
        this.question = '';
        this.answer = '';
        this.page = 1;
    }

    async runSearch() {
        if (this.searchDisabled) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = '';
        this.answer = '';
        try {
            const resp = await search({ query: this.searchKey, recordTypes: this.types });
            this.results = resp.results || [];
            this.keywords = resp.keywords || [];
            this.minYears = resp.minYears;
            this.page = 1;
            this.searched = true;
        } catch (e) {
            this.results = [];
            this.errorMessage = this.errorText(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ---------------- ask AI ----------------

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
        this.answer = '';
        const q = this.question && this.question.trim() ? this.question.trim() : 'Summarise these results: ' + this.searchKey;
        try {
            this.answer = await summarize({ query: q, accountIds: this.results.map((r) => r.id) });
        } catch (e) {
            this.answer = `<p>${this.errorText(e)}</p>`;
        } finally {
            this.answerLoading = false;
        }
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
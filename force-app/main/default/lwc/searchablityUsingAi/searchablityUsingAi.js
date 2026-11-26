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

/**
 * Magic Search v2 (26-11-2026): plain-English search over candidates (and optionally employees and contractors),
 * their skills, certifications and projects. Safe search in Apex (CandidateSearchController); an AI summary
 * of the top results is optional and only runs when the user clicks it.
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
    summary = '';
    summaryLoading = false;

    typeOptions = [
        { label: 'Candidates', value: 'Candidates' },
        { label: 'Employees', value: 'Employee' },
        { label: 'Contractors', value: 'Contractor' }
    ];

    get examples() {
        return EXAMPLES.map((e) => ({ label: e }));
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
        return `${n} ${n === 1 ? 'match' : 'matches'}` + (n >= 100 ? ' (top 100 shown)' : '');
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
            experienceText: r.experience !== undefined && r.experience !== null ? `${r.experience} yrs` : 'Experience not given',
            matchText: total ? `Matches ${r.score} of ${total}: ${r.matched.join(', ')}` : '',
            matchClass: total && r.score === total ? 'match match-full' : 'match',
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
        if (this.page > 1) this.page -= 1;
    }
    handleNext() {
        if (this.page < this.pageCount) this.page += 1;
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
    handleTypes(event) {
        this.types = event.detail.value;
    }
    handleExample(event) {
        this.searchKey = event.target.label;
        this.runSearch();
    }

    async runSearch() {
        this.isLoading = true;
        this.errorMessage = '';
        this.summary = '';
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

    async handleSummary() {
        this.summaryLoading = true;
        this.summary = '';
        try {
            this.summary = await summarize({ query: this.searchKey, accountIds: this.results.map((r) => r.id) });
        } catch (e) {
            this.summary = `<p>${this.errorText(e)}</p>`;
        } finally {
            this.summaryLoading = false;
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

import { LightningElement,track } from 'lwc';
import uploadFile from '@salesforce/apex/QbayPromptSearch.getPromptSOQL'
import refinePrompt from '@salesforce/apex/QbayPromptSearch.refinePrompt';
export default class SearchablityUsingAi extends LightningElement {
    isLoading = false;
    @track searchKey = '';
    @track htmlOutput = '';
    handleSearchChange(event){
        this.searchKey = event.target.value;
    }

    uploadFile() {
        if (!this.searchKey) {
            return;
        }
        this.showResults = true;
        this.isLoading = true;
        uploadFile({ userInput: this.searchKey })
            .then(result => {
                console.log('Search Results:', result);
                // Process the result as needed, e.g., display it in the UI
                return refinePrompt({
                    userInput: this.searchKey,
                    rawData: JSON.stringify(result)
                });
            }).then(finalResponse => {
                console.log('HTML Output from refinePrompt:', finalResponse);
                this.htmlOutput = finalResponse; // safe HTML assumed

 /* Inject raw HTML manually  (Added newly upto line33)
    // Wait for next tick to ensure the DOM is ready
    requestAnimationFrame(() => {
        const container = this.template.querySelector('.injected-html');
        if (container) {
            container.innerHTML = this.htmlOutput;
        }
    });*/
            })
            .catch(error => {
                console.error('Error fetching search results:', error);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }
}
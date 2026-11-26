import { LightningElement } from 'lwc';

export default class HomeSelection extends LightningElement {
    activeTab = '1';

    handleActive(event) {
        this.activeTab = event.target.value;
    }

    // New upload results: refresh the inbox below the uploader
    handleUploaded() {
        const inbox = this.template.querySelector('c-intake-inbox');
        if (inbox) {
            inbox.refresh();
        }
    }
}
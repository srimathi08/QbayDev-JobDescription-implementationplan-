import { LightningElement, api } from 'lwc';
import resouces from '@salesforce/resourceUrl/suitcase';

export default class DragAndDropList extends LightningElement {
    @api records
    @api stage
    
    resource=resouces
    get filteredRecords() {
        if (!this.records || !this.stage) {
            return [];
        }

        return this.records.filter(record => record.StageName === this.stage);
    }

    get hasRecords() {
        return this.filteredRecords.length > 0;
    }


    handleItemDrag(evt){
        const event = new CustomEvent('listitemdrag', {
            detail: evt.detail
        })
        this.dispatchEvent(event)
    }
    handleDragOver(evt){
        evt.preventDefault()
    }
    handleDrop(evt){
        const event = new CustomEvent('itemdrop', {
            detail: this.stage
        })
        this.dispatchEvent(event)
    }
}
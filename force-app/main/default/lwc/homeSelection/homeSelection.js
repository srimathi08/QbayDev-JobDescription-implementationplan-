import { LightningElement } from 'lwc';

export default class HomeSelection extends LightningElement {
    activeTab = '1';
    handleActive(event) {
     this.activeTab = event.target.value;
    }
}
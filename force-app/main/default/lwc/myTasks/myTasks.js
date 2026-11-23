/*import { LightningElement, track } from 'lwc';
import getTasks from '@salesforce/apex/TaskTabsController.getTasks';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

export default class TaskTabs extends NavigationMixin(LightningElement) {
  @track activeTab = 'OPEN';
  @track rows = [];
  @track loaded = false;

  connectedCallback() {
    this.load();
  }

  // Fired by each <lightning-tab onactive={handleTabChange}>
  handleTabChange(event) {
    const v = event?.target?.value;
    if (!v || v === this.activeTab) return;
    this.activeTab = v.toUpperCase();
    this.load();
  }

  async load() {
    this.loaded = false;
    this.rows = [];
    try {
      const data = await getTasks({ viewName: this.activeTab });
      const todayMidnight = new Date(); // normalize to midnight
      todayMidnight.setHours(0, 0, 0, 0);

      this.rows = (data || []).map(r => {
        const link = `/lightning/r/Task/${r.Id}/view`;
        const ownerName = r.Owner ? r.Owner.Name : '';

        // Format Due Date & overdue
        let displayDate = '—';
        let isOverdue = false;
        if (r.ActivityDate) {
          const dt = new Date(r.ActivityDate);
          const dMidnight = new Date(dt.getTime());
          dMidnight.setHours(0, 0, 0, 0);
          displayDate = new Intl.DateTimeFormat('en-US', {
            year: 'numeric',
            month: 'short',
            day: '2-digit'
          }).format(dt);
          isOverdue = dMidnight < todayMidnight && r.Status !== 'Completed';
        }

        // Priority pill styling
        const priorityClass = `pill pill--${(r.Priority || 'Normal').toLowerCase()}`;

        return {
          ...r,
          link,
          OwnerName: ownerName,
          ActivityDateDisplay: displayDate,
          dueClass: isOverdue ? 'value value--overdue' : 'value',
          priorityClass
        };
      });
    } catch (e) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Error loading tasks',
          message: e?.body?.message || e.message,
          variant: 'error'
        })
      );
    } finally {
      this.loaded = true;
    }
  }

  openNewTask() {
    this[NavigationMixin.Navigate]({
      type: 'standard__objectPage',
      attributes: { objectApiName: 'Task', actionName: 'new' }
    });
    // naive refresh after user closes the new-record modal
    setTimeout(() => this.load(), 1500);
  }

  handleOpenRecord(event) {
    event.preventDefault();
    const id = event.currentTarget?.dataset?.id;
    if (!id) return;
    this[NavigationMixin.Navigate]({
      type: 'standard__recordPage',
      attributes: { recordId: id, objectApiName: 'Task', actionName: 'view' }
    });
  }
}   */



import { LightningElement, track } from 'lwc';
import getTasks from '@salesforce/apex/TaskTabsController.getTasks';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

export default class TaskTabs extends NavigationMixin(LightningElement) {
  @track activeTab = 'OPEN';
  @track rows = [];
  @track loaded = false;

  connectedCallback() {
    this.load();
  }

  handleTabChange(event) {
    const v = event?.target?.value;
    if (!v || v === this.activeTab) return;
    this.activeTab = v.toUpperCase();
    this.load();
  }

  async load() {
    this.loaded = false;
    this.rows = [];
    try {
      const data = await getTasks({ viewName: this.activeTab });
      const todayMidnight = new Date();
      todayMidnight.setHours(0, 0, 0, 0);

      this.rows = (data || []).map(r => {
        const link = `/lightning/r/Task/${r.Id}/view`;
        const ownerName = r.Owner ? r.Owner.Name : '';

        // Format Due Date & overdue flag
        let displayDate = '—';
        let isOverdue = false;
        if (r.ActivityDate) {
          const dt = new Date(r.ActivityDate);
          const dMidnight = new Date(dt.getTime());
          dMidnight.setHours(0, 0, 0, 0);
          displayDate = new Intl.DateTimeFormat('en-US', {
            year: 'numeric',
            month: 'short',
            day: '2-digit'
          }).format(dt);
          isOverdue = dMidnight < todayMidnight && r.Status !== 'Completed';
        }

        const priorityClass = `pill pill--${(r.Priority || 'Normal').toLowerCase()}`;

        return {
          ...r,
          link,
          OwnerName: ownerName,
          ActivityDateDisplay: displayDate,
          dueClass: isOverdue ? 'value value--overdue' : 'value',
          priorityClass
        };
      });
    } catch (e) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Error loading tasks',
          message: e?.body?.message || e.message,
          variant: 'error'
        })
      );
    } finally {
      this.loaded = true;
    }
  }

  openNewTask() {
    this[NavigationMixin.Navigate]({
      type: 'standard__objectPage',
      attributes: { objectApiName: 'Task', actionName: 'new' }
    });
    // Light refresh after modal closes
    setTimeout(() => this.load(), 1500);
  }

  handleOpenRecord(event) {
    event.preventDefault();
    const id = event.currentTarget?.dataset?.id;
    if (!id) return;
    this[NavigationMixin.Navigate]({
      type: 'standard__recordPage',
      attributes: { recordId: id, objectApiName: 'Task', actionName: 'view' }
    });
  }
}
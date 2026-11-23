import { LightningElement, api, wire, track } from 'lwc';
import getProjectExperiences from '@salesforce/apex/ProjectTimelineController.getProjectExperiences';

export default class ProjectTimeline extends LightningElement {
    @api recordId;
    @track projects;
    error;

    @wire(getProjectExperiences, { accountId: '$recordId' })
    wiredProjects({ error, data }) {
        if (data) {
            // Add isExpanded and label fields
            this.projects = data.map(proj => ({
                ...proj,
                isExpanded: false,
                label: '▼'
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.projects = undefined;
        }
    }

    toggleDetails(event) {
        const projectId = event.currentTarget.dataset.id;
        this.projects = this.projects.map(proj => {
            if (proj.id === projectId) {
                const expanded = !proj.isExpanded;
                return {
                    ...proj,
                    isExpanded: expanded,
                    label: expanded ? '▲ Hide' : '▼'
                };
            }
            return proj;
        });
    }
}
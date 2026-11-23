import { LightningElement, api } from 'lwc';
import getCategoryCounts from '@salesforce/apex/EmployeeSkillChartController.getCategoryCounts';

import chartjs from '@salesforce/resourceUrl/ChartJS';
import { loadScript } from 'lightning/platformResourceLoader';

export default class EmployeeSkillChart extends LightningElement {
    @api recordId;

    chart;
    chartJsInitialized = false;
    error;

    renderedCallback() {
        if (this.chartJsInitialized) return;

        this.chartJsInitialized = true;

        // Load Chart.js from static resource
        loadScript(this, chartjs)
            .then(() => {
                this.loadChartData(); // only after Chart is loaded
            })
            .catch(error => {
                this.error = 'Chart.js failed to load';
                console.error(error);
            });
    }

    loadChartData() {
        getCategoryCounts({ accountId: this.recordId })
            .then(data => {
                const labels = Object.keys(data);
                const values = Object.values(data);
                this.renderChart(labels, values);
            })
            .catch(error => {
                this.error = error.body?.message || error.message;
                console.error(error);
            });
    }

    renderChart(labels, values) {
        const canvas = this.template.querySelector('canvas');

        if (this.chart) {
            this.chart.destroy();
        }

        this.chart = new window.Chart(canvas, {
            type: 'bar',
            data: {
                labels: labels,
                datasets: [{
                    label: '',
                    data: values,
                    backgroundColor: 'rgba(75, 192, 192, 0.6)',
                    borderColor: 'rgba(75, 192, 192, 1)',
                    borderWidth: 1
                }]
            },
            options: {
                responsive: true,
                scales: {
                    y: {
                        beginAtZero: true
                    }
                }
            }
        });
    }
}
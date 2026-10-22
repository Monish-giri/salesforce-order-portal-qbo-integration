import { LightningElement, wire } from 'lwc';
import getReturns from '@salesforce/apex/PortalReturnService.getReturns';
import { refreshApex } from '@salesforce/apex';

export default class PortalReturns extends LightningElement {
    returns = [];
    errorMessage;
    wiredReturnsResult;
    isLoading = true;

    @wire(getReturns)
    wiredReturns(result) {
        this.wiredReturnsResult = result;
        const { data, error } = result;
        if (data) {
            this.returns = data.map(item => ({
                ...item,
                statusClass: this.getStatusClass(item.status),
                resolutionLabel: item.resolutionType || 'Pending business decision',
                amountLabel: item.totalAmount || 0
            }));
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            this.returns = [];
            this.errorMessage = this.getErrorMessage(error);
            this.isLoading = false;
        }
    }

    async refreshReturns() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            await refreshApex(this.wiredReturnsResult);
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
        } finally {
            this.isLoading = false;
        }
    }

    get hasReturns() {
        return this.returns.length > 0;
    }

    get showEmpty() {
        return !this.isLoading && !this.errorMessage && !this.hasReturns;
    }

    getStatusClass(status) {
        const normalized = (status || '').toLowerCase();
        if (normalized === 'credited' || normalized === 'refunded') return 'status-badge success';
        if (normalized === 'failed' || normalized === 'rejected') return 'status-badge danger';
        if (normalized === 'approved' || normalized === 'processing') return 'status-badge progress';
        return 'status-badge pending';
    }

    getErrorMessage(error) {
        return error?.body?.message || error?.message || 'Unable to load returns.';
    }
}

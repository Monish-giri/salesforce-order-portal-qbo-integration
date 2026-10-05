import { LightningElement, api } from 'lwc';
import getCheckoutContext from '@salesforce/apex/OrderSubmissionService.getCheckoutContext';
import submitOrder from '@salesforce/apex/OrderSubmissionService.submitOrder';

export default class PortalCheckout extends LightningElement {
    @api cartItems = [];

    isLoading = true;
    isSubmitting = false;
    errorMessage;

    context;
    selectedAccountId;

    connectedCallback() {
        this.loadCheckoutContext();
    }

    get isPartner() {
        return this.context?.isPartner === true;
    }

    get customerOptions() {
        return (this.context?.customerAccounts ?? []).map((account) => ({
            label: account.name,
            value: account.id
        }));
    }

    get orderAccountName() {
        const selected = (this.context?.customerAccounts ?? []).find(
            account => account.id === this.selectedAccountId
        );
        return selected?.name || this.context?.defaultOrderAccountName || 'Customer account';
    }

    get itemCount() {
        return this.cartItems.reduce((total, item) => total + item.quantity, 0);
    }

    get cartSubtotal() {
        return this.cartItems.reduce(
            (total, item) => total + (item.unitPrice * item.quantity),
            0
        );
    }

    async loadCheckoutContext() {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            this.context = await getCheckoutContext();
            this.selectedAccountId = this.context?.defaultOrderAccountId;
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
    }

    async handlePlaceOrder() {
        if (!this.cartItems.length || !this.selectedAccountId) {
            this.errorMessage = 'Select a customer account before placing the order.';
            return;
        }

        this.isSubmitting = true;
        this.errorMessage = undefined;

        try {
            const result = await submitOrder({
                cartJson: JSON.stringify(
                    this.cartItems.map(item => ({
                        pricebookEntryId: item.pricebookEntryId,
                        quantity: item.quantity
                    }))
                ),
                submissionKey: this.createSubmissionKey(),
                orderForAccountId: this.selectedAccountId
            });

            this.dispatchEvent(
                new CustomEvent('ordersubmitted', {
                    detail: result
                })
            );
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('backtocart'));
    }

    createSubmissionKey() {
        return `portal-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`;
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }

        if (Array.isArray(error?.body) && error.body.length > 0) {
            return error.body.map(item => item.message).join(', ');
        }

        return 'An unexpected error occurred while processing the order.';
    }
}

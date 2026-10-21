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
    selectedPaymentMethod = 'Online';

    connectedCallback() { this.loadCheckoutContext(); }

    get isPartner() { return this.context?.isPartner === true; }
    get isCustomer() { return this.context?.isPartner === false; }

    get customerOptions() {
        return (this.context?.customerAccounts ?? []).map((account) => ({ label: account.name, value: account.id }));
    }

    get paymentOptions() {
        if (this.isPartner) {
            return [
                { label: 'B2B Invoice / Credit Terms', value: 'Invoice' }
            ];
        }

        return [
            { label: 'Pay Online', value: 'Online' },
            { label: 'Cash on Delivery', value: 'Cash on Delivery' }
        ];
    }

    get paymentHeading() {
        return this.isPartner ? 'B2B payment terms' : 'Choose your payment method';
    }

    get orderAccountName() {
        const selected = (this.context?.customerAccounts ?? []).find(account => account.id === this.selectedAccountId);
        return selected?.name || this.context?.defaultOrderAccountName || 'Customer account';
    }

    get itemCount() { return this.cartItems.reduce((total, item) => total + item.quantity, 0); }

    get cartSubtotal() {
        return this.cartItems.reduce((total, item) => total + (item.unitPrice * item.quantity), 0);
    }

    get b2bRecommendedRetailTotal() {
        if (!this.isPartner) return 0;
        return this.cartItems.reduce((total, item) => total + ((item.recommendedRetailPrice || 0) * item.quantity), 0);
    }

    get b2bEstimatedMarginTotal() {
        if (!this.isPartner) return 0;
        return this.cartItems.reduce((total, item) => total + ((item.estimatedMarginAmount || 0) * item.quantity), 0);
    }

    get b2bEstimatedMarginPercent() {
        if (!this.isPartner || !this.b2bRecommendedRetailTotal) return 0;
        return (this.b2bEstimatedMarginTotal / this.b2bRecommendedRetailTotal) * 100;
    }

    get hasB2BMarginData() { return this.isPartner && this.b2bRecommendedRetailTotal > 0; }

    get paymentSummary() {
        if (this.isPartner) {
            return 'Your order will be invoiced with the configured B2B payment terms. Early-payment discounts will be shown on the invoice when applicable.';
        }
        if (this.selectedPaymentMethod === 'Cash on Delivery') return 'Pay the full order amount when your order is delivered.';
        return 'Pay the full order amount online. Razorpay will be connected in the payment integration phase.';
    }

    async loadCheckoutContext() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.context = await getCheckoutContext();
            this.selectedAccountId = this.context?.defaultOrderAccountId;
            this.selectedPaymentMethod = this.context?.isPartner ? 'Invoice' : 'Online';
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleAccountChange(event) { this.selectedAccountId = event.detail.value; }
    handlePaymentMethodChange(event) { this.selectedPaymentMethod = event.detail.value; }

    async handlePlaceOrder() {
        if (!this.cartItems.length || !this.selectedAccountId) {
            this.errorMessage = 'Select a customer account before placing the order.';
            return;
        }
        if (!this.selectedPaymentMethod) {
            this.errorMessage = 'Select a payment method before placing the order.';
            return;
        }

        this.isSubmitting = true;
        this.errorMessage = undefined;
        try {
            const result = await submitOrder({
                cartJson: JSON.stringify(this.cartItems.map(item => ({
                    pricebookEntryId: item.pricebookEntryId,
                    quantity: item.quantity
                }))),
                submissionKey: this.createSubmissionKey(),
                orderForAccountId: this.selectedAccountId,
                paymentMethod: this.selectedPaymentMethod
            });
            this.dispatchEvent(new CustomEvent('ordersubmitted', { detail: result }));
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isSubmitting = false;
        }
    }

    handleBack() { this.dispatchEvent(new CustomEvent('backtocart')); }
    createSubmissionKey() { return `portal-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`; }

    reduceError(error) {
        if (error?.body?.message) return error.body.message;
        if (Array.isArray(error?.body) && error.body.length > 0) return error.body.map(item => item.message).join(', ');
        return 'An unexpected error occurred while processing the order.';
    }
}

import { LightningElement } from 'lwc';
import getProducts from '@salesforce/apex/PortalCatalogService.getProducts';

const PAGE_SIZE = 24;
const SEARCH_DELAY = 350;

export default class PortalCatalog extends LightningElement {
    products = [];
    searchTerm = '';
    isLoading = true;
    errorMessage;
    hasMore = false;
    audience = 'Customer';
    isPartner = false;

    searchTimer;

    connectedCallback() {
        this.loadProducts();
    }

    disconnectedCallback() {
        window.clearTimeout(this.searchTimer);
    }

    get hasProducts() {
        return this.products.length > 0;
    }

    get catalogTitle() {
        return this.isPartner ? 'Partner Product Catalog' : 'Product Catalog';
    }

    get catalogSubtitle() {
        return this.isPartner
            ? 'View partner pricing and choose the products for your order.'
            : 'Choose the products and services available to your account.';
    }

    handleSearchInput(event) {
        this.searchTerm = event.target.value;

        window.clearTimeout(this.searchTimer);
        this.searchTimer = window.setTimeout(() => {
            this.loadProducts();
        }, SEARCH_DELAY);
    }

    async loadProducts() {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const response = await getProducts({
                searchTerm: this.searchTerm,
                pageSize: PAGE_SIZE
            });

            this.audience = response?.audience ?? 'Customer';
            this.isPartner = response?.isPartner === true;

            this.products = (response?.products ?? []).map((product) => ({
                ...product,
                isSelectingQuantity: false,
                selectedQuantity: 1,
                quantityInputId: `quantity-${product.pricebookEntryId}`
            }));
            this.hasMore = response?.hasMore ?? false;
        } catch (error) {
            this.products = [];
            this.hasMore = false;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleAddToCart(event) {
        this.setQuantitySelectorState(event.currentTarget.dataset.id, true);
    }

    handleIncreaseQuantity(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;

        this.products = this.products.map((product) =>
            product.pricebookEntryId === pricebookEntryId
                ? {
                    ...product,
                    selectedQuantity: product.selectedQuantity + 1
                }
                : product
        );
    }

    handleDecreaseQuantity(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;

        this.products = this.products.map((product) =>
            product.pricebookEntryId === pricebookEntryId
                ? {
                    ...product,
                    selectedQuantity: Math.max(1, product.selectedQuantity - 1)
                }
                : product
        );
    }

    handleQuantityInput(event) {
        const pricebookEntryId = event.target.dataset.id;
        const value = Number(event.target.value);

        if (!Number.isInteger(value) || value < 1) {
            this.updateSelectedQuantity(pricebookEntryId, 1);
            return;
        }

        this.updateSelectedQuantity(pricebookEntryId, value);
    }

    handleConfirmAddToCart(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(
            item => item.pricebookEntryId === pricebookEntryId
        );

        if (!product || !Number.isInteger(product.selectedQuantity) || product.selectedQuantity < 1) {
            return;
        }

        this.dispatchEvent(
            new CustomEvent('addtocart', {
                detail: {
                    productId: product.productId,
                    pricebookEntryId: product.pricebookEntryId,
                    name: product.name,
                    unitPrice: product.unitPrice,
                    recommendedRetailPrice: this.isPartner ? product.recommendedRetailPrice : undefined,
                    estimatedMarginAmount: this.isPartner ? product.estimatedMarginAmount : undefined,
                    estimatedMarginPercent: this.isPartner ? product.estimatedMarginPercent : undefined,
                    quantity: product.selectedQuantity
                }
            })
        );

        this.setQuantitySelectorState(pricebookEntryId, false);
    }

    setQuantitySelectorState(pricebookEntryId, isSelectingQuantity) {
        this.products = this.products.map((product) =>
            product.pricebookEntryId === pricebookEntryId
                ? {
                    ...product,
                    isSelectingQuantity,
                    selectedQuantity: isSelectingQuantity ? 1 : product.selectedQuantity
                }
                : product
        );
    }

    updateSelectedQuantity(pricebookEntryId, selectedQuantity) {
        this.products = this.products.map((product) =>
            product.pricebookEntryId === pricebookEntryId
                ? { ...product, selectedQuantity }
                : product
        );
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }

        if (Array.isArray(error?.body) && error.body.length > 0) {
            return error.body.map(item => item.message).join(', ');
        }

        return 'An unexpected error occurred while loading the catalog.';
    }
}

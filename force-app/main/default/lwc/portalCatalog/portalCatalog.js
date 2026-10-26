import { LightningElement } from 'lwc';
import getProducts from '@salesforce/apex/PortalCatalogService.getProducts';

const PAGE_SIZE = 24;
const SEARCH_DELAY = 350;
const HOVER_INTERVAL = 1800;

export default class PortalCatalog extends LightningElement {
    products = [];
    searchTerm = '';
    isLoading = true;
    errorMessage;
    hasMore = false;
    audience = 'Customer';
    isPartner = false;

    isGalleryOpen = false;
    galleryProduct;
    galleryIndex = 0;

    searchTimer;
    hoverTimer;
    hoveredProductId;
    touchStartX;

    connectedCallback() {
        this.loadProducts();
    }

    disconnectedCallback() {
        window.clearTimeout(this.searchTimer);
        this.clearHoverTimer();
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

    get galleryImageUrl() {
        return this.galleryProduct?.imageUrls?.[this.galleryIndex];
    }

    get galleryHasMultipleImages() {
        return (this.galleryProduct?.imageUrls?.length ?? 0) > 1;
    }

    get galleryCounter() {
        if (!this.galleryProduct) return '';
        return `${this.galleryIndex + 1} / ${this.galleryProduct.imageUrls.length}`;
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
        this.closeGallery();
        this.clearHoverTimer();

        try {
            const response = await getProducts({
                searchTerm: this.searchTerm,
                pageSize: PAGE_SIZE
            });

            this.audience = response?.audience ?? 'Customer';
            this.isPartner = response?.isPartner === true;

            this.products = (response?.products ?? []).map((product) => {
                const imageUrls = Array.isArray(product.imageUrls) ? product.imageUrls : [];
                const hoverImageIndex = 0;

                return {
                    ...product,
                    imageUrls,
                    hasImages: imageUrls.length > 0,
                    imageCount: imageUrls.length,
                    isSelectingQuantity: false,
                    isImageHovering: false,
                    hoverImageIndex,
                    hoverImageUrl: imageUrls[hoverImageIndex],
                    hoverImageCounter: imageUrls.length ? `1 / ${imageUrls.length}` : '',
                    selectedQuantity: 1,
                    quantityInputId: `quantity-${product.pricebookEntryId}`
                };
            });
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

    handleProductNameEnter(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);

        if (!product?.hasImages) return;

        this.clearHoverTimer();
        this.hoveredProductId = pricebookEntryId;
        this.products = this.products.map((item) => ({
            ...item,
            isImageHovering: item.pricebookEntryId === pricebookEntryId,
            hoverImageIndex: item.pricebookEntryId === pricebookEntryId ? 0 : item.hoverImageIndex,
            hoverImageUrl: item.pricebookEntryId === pricebookEntryId ? item.imageUrls[0] : item.hoverImageUrl,
            hoverImageCounter: item.pricebookEntryId === pricebookEntryId ? `1 / ${item.imageCount}` : item.hoverImageCounter
        }));

        if (product.imageUrls.length > 1) {
            this.hoverTimer = window.setInterval(() => {
                this.advanceHoverImage();
            }, HOVER_INTERVAL);
        }
    }

    handleProductNameLeave() {
        this.clearHoverTimer();
        this.hoveredProductId = undefined;
        this.products = this.products.map((item) => ({
            ...item,
            isImageHovering: false
        }));
    }

    advanceHoverImage() {
        if (!this.hoveredProductId) return;

        this.products = this.products.map((product) => {
            if (product.pricebookEntryId !== this.hoveredProductId) return product;

            const imageCount = product.imageUrls.length;
            const hoverImageIndex = imageCount > 0
                ? (product.hoverImageIndex + 1) % imageCount
                : 0;

            return {
                ...product,
                hoverImageIndex,
                hoverImageUrl: product.imageUrls[hoverImageIndex],
                hoverImageCounter: imageCount ? `${hoverImageIndex + 1} / ${imageCount}` : ''
            };
        });
    }

    handleOpenGallery(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);

        if (!product?.hasImages) return;

        this.clearHoverTimer();
        this.galleryProduct = product;
        this.galleryIndex = 0;
        this.isGalleryOpen = true;
    }

    handleGalleryPrevious() {
        if (!this.galleryHasMultipleImages) return;
        const count = this.galleryProduct.imageUrls.length;
        this.galleryIndex = (this.galleryIndex - 1 + count) % count;
    }

    handleGalleryNext() {
        if (!this.galleryHasMultipleImages) return;
        const count = this.galleryProduct.imageUrls.length;
        this.galleryIndex = (this.galleryIndex + 1) % count;
    }

    handleGalleryKeydown(event) {
        if (event.key === 'Escape') {
            this.closeGallery();
        } else if (event.key === 'ArrowLeft') {
            this.handleGalleryPrevious();
        } else if (event.key === 'ArrowRight') {
            this.handleGalleryNext();
        }
    }

    handleGalleryBackdropClick(event) {
        if (event.target === event.currentTarget) {
            this.closeGallery();
        }
    }

    handleGalleryTouchStart(event) {
        this.touchStartX = event.touches[0].clientX;
    }

    handleGalleryTouchEnd(event) {
        if (this.touchStartX == null) return;

        const touchEndX = event.changedTouches[0].clientX;
        const delta = touchEndX - this.touchStartX;
        this.touchStartX = undefined;

        if (Math.abs(delta) < 40) return;
        if (delta > 0) {
            this.handleGalleryPrevious();
        } else {
            this.handleGalleryNext();
        }
    }

    closeGallery() {
        this.isGalleryOpen = false;
        this.galleryProduct = undefined;
        this.galleryIndex = 0;
        this.touchStartX = undefined;
    }

    clearHoverTimer() {
        if (this.hoverTimer) {
            window.clearInterval(this.hoverTimer);
            this.hoverTimer = undefined;
        }
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

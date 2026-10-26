import { LightningElement, api } from 'lwc';
import getProducts from '@salesforce/apex/PortalCatalogService.getProducts';

const PAGE_SIZE = 24;
const SEARCH_DELAY = 350;
const HOVER_CAROUSEL_INTERVAL = 2000;
const HOVER_IMAGE_FADE_DURATION = 700;

export default class PortalCatalog extends LightningElement {
    products = [];
    searchTerm = '';
    isLoading = true;
    errorMessage;
    hasMore = false;
    audience = 'Customer';
    isPartner = false;

    selectedImageProduct;
    selectedImageIndex = 0;
    touchStartX;

    searchTimer;
    previewTimers = new Map();
    previewTransitionTimers = new Map();
    _cartItems = [];

    @api
    get cartItems() {
        return this._cartItems;
    }

    set cartItems(value) {
        this._cartItems = Array.isArray(value) ? value : [];
        this.syncCartQuantities();
    }

    connectedCallback() {
        this.loadProducts();
    }

    disconnectedCallback() {
        window.clearTimeout(this.searchTimer);
        this.clearAllPreviewTimers();
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

    get hasSelectedImages() {
        return Boolean(this.selectedImageProduct?.imageUrls?.length);
    }

    get selectedImageUrl() {
        if (!this.hasSelectedImages) {
            return undefined;
        }

        return this.selectedImageProduct.imageUrls[this.selectedImageIndex];
    }

    get selectedImageCounter() {
        if (!this.hasSelectedImages) {
            return '';
        }

        return `${this.selectedImageIndex + 1} / ${this.selectedImageProduct.imageUrls.length}`;
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
        this.closeImageModal();
        this.clearAllPreviewTimers();

        try {
            const response = await getProducts({
                searchTerm: this.searchTerm,
                pageSize: PAGE_SIZE
            });

            this.audience = response?.audience ?? 'Customer';
            this.isPartner = response?.isPartner === true;

            this.products = (response?.products ?? []).map((product) => {
                const imageUrls = product.imageUrls ?? [];
                const cartQuantity = this.getCartQuantity(product.pricebookEntryId);

                return {
                    ...product,
                    imageUrls,
                    hasImages: imageUrls.length > 0,
                    isImagePreviewVisible: false,
                    currentImageIndex: 0,
                    currentImageUrl: imageUrls[0],
                    previewImageClass: 'preview-image',
                    cartQuantity,
                    isInCart: cartQuantity > 0,
                    isSingleQuantity: cartQuantity === 1,
                    quantityDecreaseTitle: cartQuantity === 1 ? 'Remove from cart' : 'Decrease quantity',
                    quantityDecreaseLabel: cartQuantity === 1 ? 'Remove from cart' : 'Decrease quantity',
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

    syncCartQuantities() {
        if (!this.products.length) {
            return;
        }

        this.products = this.products.map((product) => {
            const cartQuantity = this.getCartQuantity(product.pricebookEntryId);

            return {
                ...product,
                cartQuantity,
                isInCart: cartQuantity > 0,
                isSingleQuantity: cartQuantity === 1,
                quantityDecreaseTitle: cartQuantity === 1 ? 'Remove from cart' : 'Decrease quantity',
                quantityDecreaseLabel: cartQuantity === 1 ? 'Remove from cart' : 'Decrease quantity'
            };
        });
    }

    getCartQuantity(pricebookEntryId) {
        const item = this._cartItems.find(
            cartItem => cartItem.pricebookEntryId === pricebookEntryId
        );

        return item?.quantity ?? 0;
    }

    handleProductMouseEnter(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);

        if (!product?.hasImages) {
            return;
        }

        this.products = this.products.map((item) =>
            item.pricebookEntryId === pricebookEntryId
                ? {
                    ...item,
                    isImagePreviewVisible: true,
                    previewImageClass: 'preview-image preview-image-fade-in'
                }
                : item
        );

        this.startHoverCarousel(pricebookEntryId);
    }

    handleProductMouseLeave(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;

        this.stopHoverCarousel(pricebookEntryId);

        this.products = this.products.map((product) =>
            product.pricebookEntryId === pricebookEntryId
                ? { ...product, isImagePreviewVisible: false }
                : product
        );
    }

    startHoverCarousel(pricebookEntryId) {
        this.stopHoverCarousel(pricebookEntryId);

        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);
        if (!product?.hasImages || product.imageUrls.length < 2) {
            return;
        }

        const timer = window.setInterval(() => {
            this.changeHoverImage(pricebookEntryId, 1);
        }, HOVER_CAROUSEL_INTERVAL);

        this.previewTimers.set(pricebookEntryId, timer);
    }

    stopHoverCarousel(pricebookEntryId) {
        const timer = this.previewTimers.get(pricebookEntryId);

        if (timer) {
            window.clearInterval(timer);
            this.previewTimers.delete(pricebookEntryId);
        }

        const transitionTimer = this.previewTransitionTimers.get(pricebookEntryId);
        if (transitionTimer) {
            window.clearTimeout(transitionTimer);
            this.previewTransitionTimers.delete(pricebookEntryId);
        }
    }

    clearAllPreviewTimers() {
        this.previewTimers.forEach(timer => window.clearInterval(timer));
        this.previewTimers.clear();

        this.previewTransitionTimers.forEach(timer => window.clearTimeout(timer));
        this.previewTransitionTimers.clear();
    }

    handlePreviousHoverImage(event) {
        event.stopPropagation();
        const pricebookEntryId = event.currentTarget.dataset.id;
        this.changeHoverImage(pricebookEntryId, -1);
    }

    handleNextHoverImage(event) {
        event.stopPropagation();
        const pricebookEntryId = event.currentTarget.dataset.id;
        this.changeHoverImage(pricebookEntryId, 1);
    }

    changeHoverImage(pricebookEntryId, direction) {
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);
        if (!product?.hasImages) {
            return;
        }

        const imageCount = product.imageUrls.length;
        const nextIndex =
            (product.currentImageIndex + direction + imageCount) % imageCount;

        const existingTransitionTimer = this.previewTransitionTimers.get(pricebookEntryId);
        if (existingTransitionTimer) {
            window.clearTimeout(existingTransitionTimer);
            this.previewTransitionTimers.delete(pricebookEntryId);
        }

        this.products = this.products.map((item) =>
            item.pricebookEntryId === pricebookEntryId
                ? { ...item, previewImageClass: 'preview-image preview-image-fade-out' }
                : item
        );

        const transitionTimer = window.setTimeout(() => {
            this.products = this.products.map((item) =>
                item.pricebookEntryId === pricebookEntryId
                    ? {
                        ...item,
                        currentImageIndex: nextIndex,
                        currentImageUrl: item.imageUrls[nextIndex],
                        previewImageClass: 'preview-image preview-image-fade-in'
                    }
                    : item
            );

            this.previewTransitionTimers.delete(pricebookEntryId);
        }, HOVER_IMAGE_FADE_DURATION);

        this.previewTransitionTimers.set(pricebookEntryId, transitionTimer);
    }

    handleOpenImageModal(event) {
        event.stopPropagation();

        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(
            item => item.pricebookEntryId === pricebookEntryId
        );

        if (!product?.hasImages) {
            return;
        }

        this.selectedImageProduct = product;
        this.selectedImageIndex = product.currentImageIndex ?? 0;
    }

    handleCloseImageModal(event) {
        if (event) {
            event.stopPropagation();
        }

        this.closeImageModal();
    }

    closeImageModal() {
        this.selectedImageProduct = undefined;
        this.selectedImageIndex = 0;
        this.touchStartX = undefined;
    }

    handleModalContentClick(event) {
        event.stopPropagation();
    }

    handlePreviousModalImage(event) {
        if (event) {
            event.stopPropagation();
        }

        const images = this.selectedImageProduct?.imageUrls ?? [];
        if (images.length === 0) {
            return;
        }

        this.selectedImageIndex =
            this.selectedImageIndex === 0
                ? images.length - 1
                : this.selectedImageIndex - 1;
    }

    handleNextModalImage(event) {
        if (event) {
            event.stopPropagation();
        }

        const images = this.selectedImageProduct?.imageUrls ?? [];
        if (images.length === 0) {
            return;
        }

        this.selectedImageIndex =
            this.selectedImageIndex === images.length - 1
                ? 0
                : this.selectedImageIndex + 1;
    }

    handleImageTouchStart(event) {
        this.touchStartX = event.changedTouches[0].screenX;
    }

    handleImageTouchEnd(event) {
        if (this.touchStartX === undefined) {
            return;
        }

        const touchEndX = event.changedTouches[0].screenX;
        const deltaX = touchEndX - this.touchStartX;
        const minimumSwipeDistance = 40;

        this.touchStartX = undefined;

        if (Math.abs(deltaX) < minimumSwipeDistance) {
            return;
        }

        if (deltaX > 0) {
            this.handlePreviousModalImage();
        } else {
            this.handleNextModalImage();
        }
    }

    handleAddToCart(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        this.dispatchCartQuantityChange(pricebookEntryId, 1);
    }

    handleIncreaseQuantity(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);

        if (!product) {
            return;
        }

        this.dispatchCartQuantityChange(pricebookEntryId, product.cartQuantity + 1);
    }

    handleDecreaseQuantity(event) {
        const pricebookEntryId = event.currentTarget.dataset.id;
        const product = this.products.find(item => item.pricebookEntryId === pricebookEntryId);

        if (!product) {
            return;
        }

        this.dispatchCartQuantityChange(pricebookEntryId, Math.max(0, product.cartQuantity - 1));
    }

    handleQuantityInput(event) {
        const pricebookEntryId = event.target.dataset.id;
        const rawValue = event.target.value;

        if (rawValue === '') {
            return;
        }

        const value = Number(rawValue);

        if (!Number.isInteger(value) || value < 1) {
            event.target.value = this.getCartQuantity(pricebookEntryId);
            return;
        }

        this.dispatchCartQuantityChange(pricebookEntryId, value);
    }

    dispatchCartQuantityChange(pricebookEntryId, quantity) {
        const product = this.products.find(
            item => item.pricebookEntryId === pricebookEntryId
        );

        if (!product) {
            return;
        }

        this.dispatchEvent(
            new CustomEvent('cartquantitychange', {
                detail: {
                    productId: product.productId,
                    pricebookEntryId: product.pricebookEntryId,
                    name: product.name,
                    unitPrice: product.unitPrice,
                    recommendedRetailPrice: this.isPartner ? product.recommendedRetailPrice : undefined,
                    estimatedMarginAmount: this.isPartner ? product.estimatedMarginAmount : undefined,
                    estimatedMarginPercent: this.isPartner ? product.estimatedMarginPercent : undefined,
                    quantity
                }
            })
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
